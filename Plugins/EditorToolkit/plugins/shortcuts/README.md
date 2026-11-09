# Shortcuts

Adds new commands to Final Cut's own **Command Editor** (Final Cut Pro → Commands → Customize…) so you can bind them to any key, like a native command.

## Why

Some of the things done most often in a RAW-heavy grade have no keyboard command at all in Final Cut. Registering them as real Command Editor commands (not a global hotkey app) means they show up in search, can be assigned like anything else, and are saved in your own command set.

## How it works

| Command | What it does |
|---|---|
| **Edit RAW Properties** | Jumps the inspector to the RAW tab for the selected BRAW clip; press again to hide the inspector |
| **Toggle Stabilization** | Turns Final Cut's Stabilization on/off for the selected clips (presses the same checkbox, so undo and multi-clip behaviour are native) |
| **Zoom to Fit (Toggle)** | Fits the whole timeline; press again to return to the exact zoom and scroll position you had |
| **Show Video Inspector** / **Show Info Inspector** | Switches to that tab; pressing again on that tab hides the inspector |

Ships with **no keys assigned**. Optional: `defaults write com.apple.FinalCut SpliceKitShortcutsRebindKey2 -bool YES` moves the plain **2** key from Show/Hide Inspector to Show Video Inspector (one time only; Cmd-4 stays as is).

## Requires

RAW Tab, for *Edit RAW Properties*. Everything else works on its own.

## Install

```sh
./install.sh shortcuts
```

Then restart Final Cut Pro. Remove with `./install.sh --uninstall shortcuts`. Log: `~/Library/Logs/SpliceKit/`.
