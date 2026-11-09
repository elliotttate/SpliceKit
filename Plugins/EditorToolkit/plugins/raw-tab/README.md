# RAW Tab

Puts Final Cut Pro's **Edit RAW Properties** controls in their own **RAW** tab in the inspector, next to Video, Color, Audio and Info.

## Why

Grading Blackmagic RAW in Final Cut means opening a floating *Edit RAW Properties* window, which sits on top of the viewer and has to be reopened for every clip. In Resolve the RAW settings simply live in a panel. RAW Tab moves the same controls into the inspector, so they follow your selection like any other inspector tab and never cover the picture.

## How it works

- Select a BRAW (or ProRes RAW) clip → a **RAW** tab appears in the inspector.
- The tab is only added when the selected clip's media really is RAW.
- Final Cut's inspector shows at most five tabs. If the list is already full, native tabs are never pushed out; only another plugin's tab (e.g. Transcript Tab) gives up its slot. Without this rule, titles silently lost their Title tab.

## Requires

The *Edit RAW Properties* panel in Final Cut (for BRAW this comes from Blackmagic's BRAW support / BRAW Toolbox).

## Install

```sh
./install.sh raw-tab
```

Then restart Final Cut Pro. Remove with `./install.sh --uninstall raw-tab`. Log: `~/Library/Logs/SpliceKit/`.

## Credits

Tab plumbing modelled on [Transcript Tab](https://github.com/bcassin/fcp-transcript-tab) (MIT).
