# XML Clips

After an XML import, every clip used in the imported timeline also shows up in the library browser.

## Why

Timelines that come from other apps (Resolve, Premiere, an online editor, a colourist) as FCPXML often open with the media linked but not in the event browser, so you can't find, re-use or relink the source clips there. This fills the browser automatically.

## How it works

- Hooks Final Cut's XML importer; after the imported timeline opens, each source clip and collection is revealed in the browser once.
- Your selection is restored afterwards.

## Requires

Nothing.

## Install

```sh
./install.sh xml-clips
```

Then restart Final Cut Pro. Remove with `./install.sh --uninstall xml-clips`. Log: `~/Library/Logs/SpliceKit/`.
