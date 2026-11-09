# Editor Toolkit for SpliceKit

Fourteen small native SpliceKit plugins for Final Cut Pro. Each one fixes a specific friction from day-to-day finishing work on fashion films, luxury commercials and branded spots, shot on a Blackmagic Cinema Camera 6K in Blackmagic RAW.

Install all of them, a themed preset, or any single plugin. Each plugin is independent, and removing one never affects the others.

## The thinking behind it

- **Final Cut stays Final Cut.** Every plugin runs through Final Cut's own actions (its Paste, Blade, Copy, inspector checkbox, Command Editor, FCPXML importer). Undo, multi-clip edits and shortcuts keep working the way an editor expects. Nothing adds a parallel UI where a native one already exists.
- **Borrow what Resolve gets right.** Many of these exist because a Resolve habit had no Final Cut equivalent: RAW settings in a panel, editing RAW across a multi-selection, gyro stabilisation as one control, flip buttons, a playback FPS readout, targeting the clip you can see.
- **Finishing timelines are layered.** Grade, film emulation, grain and letterbox adjustment layers sit on top of everything. One naming rule (put `lock` in the clip name) drives several plugins: those layers can't be selected by accident, the inspector looks through them, pastes land under them, and Blade/Copy skip them.
- **Small, single-purpose, removable.** One feature per plugin and one source file per plugin. Each logs to `~/Library/Logs/SpliceKit/` and falls back to doing nothing if the Final Cut internals it needs aren't there.

## Plugins

| Plugin | What it does | Preset |
|---|---|---|
| [RAW Tab](plugins/raw-tab) | Edit RAW Properties as its own inspector tab | `@raw` |
| [RAW Multi](plugins/raw-multi) | RAW controls stay editable across a multi-clip selection | `@raw` |
| [RAW Gyro Presets](plugins/raw-gyro) | One-click gyro stabilisation presets plus a single strength dial | `@raw` |
| [Shortcuts](plugins/shortcuts) | Command Editor commands: Edit RAW Properties, Toggle Stabilization, Zoom to Fit toggle, Show Video/Info Inspector | `@raw` |
| [Grade Lock](plugins/grade-lock) | Clips named `…lock…` can't be selected without Option | `@lock` |
| [Grade Lock Skim](plugins/grade-lock-skim) | The inspector and skimmer look through locked layers | `@lock` |
| [Paste Below Lock](plugins/paste-below-lock) | Pasted clips land under locked adjustment layers | `@lock` |
| [Topmost Clip Editing](plugins/topmost) | With nothing selected, Blade/Copy act on the top visible clip | `@lock` `@editing` |
| [Batch Sync Audio](plugins/audio-sync) | Waveform-sync many clips to external recordings in one go | `@editing` |
| [XML Clips](plugins/xml-clips) | After an XML import, the timeline's clips appear in the browser | `@editing` |
| [Flip](plugins/flip) | Flip H/V buttons and an Image Orientation menu in Transform | `@editing` |
| [Playback Frame Rate](plugins/fps-meter) | Live delivered-FPS and dropped-frame readout in the viewer | `@monitoring` |
| [Workspace Collapse](plugins/workspace-collapse) | The timeline takes the full height in a vertical workspace | `@workspace` |
| [Workspace Fix](plugins/workspace-fix) | Stops a crash when a custom workspace is applied | `@workspace` |

Each folder has its own README covering what the plugin does, why it exists, how it works and what it needs.

## Install

Requirements: Apple Silicon Mac, Final Cut Pro with SpliceKit running, and Apple's command line tools (`xcode-select --install`).

```sh
cd Plugins/EditorToolkit
./install.sh --list            # see everything
./install.sh --all             # install every plugin
./install.sh @raw              # install a preset
./install.sh raw-tab flip      # install individual plugins
./install.sh --uninstall flip  # remove one
```

Restart Final Cut Pro afterwards. Plugins are built from source, ad-hoc signed, and copied to `~/Library/Application Support/SpliceKit/plugins/<name>/` (each with its `plugin.json`).

**No compiler? Use the ready-made download.** Get a zip from the [Releases page](https://github.com/ishubhampratap/SpliceKit/releases): `EditorToolkit-All.zip`, a preset, or a single plugin. Unzip it, right-click **Install.command → Open**, then restart Final Cut Pro. Each zip has `Uninstall.command` and a `READ ME FIRST.txt` too. (`./install.sh --package` builds these zips into `dist/`.)

## Tested on

Final Cut Pro 12.4 (build 454072), SpliceKit 3.3.9, macOS 27.2, Apple Silicon. The plugins rely on private Final Cut classes, so a Final Cut update can break any of them. Each checks for what it needs at load time and logs what it found.

## Layout

```
Plugins/EditorToolkit/
├── install.sh                 build / install / uninstall / package
├── dist-templates/            Install / Uninstall / READ ME FIRST for the download zips
└── plugins/<name>/
    ├── <Source>.m             the whole plugin, one file
    ├── plugin.json            SpliceKit manifest
    ├── build.env              source, product and frameworks for install.sh
    └── README.md
```

## Credits

By Shubham Pratap. RAW Tab's inspector-tab plumbing is modelled on [Transcript Tab](https://github.com/bcassin/fcp-transcript-tab) (MIT). MIT licensed, like SpliceKit.
