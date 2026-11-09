# Workspace Collapse

For a vertical workspace where the **Browser and Inspector share one row above the timeline**: closing both collapses the row so the timeline gets the full height, closing only the Browser lets the Inspector fill the row, and reopening restores everything as it was.

## Why

A vertical layout on a portrait or tall monitor is great for the timeline, but Final Cut leaves a blank band when both upper panels are closed, and a blank strip when only one is closed (the Inspector can't grow past its maximum width).

## How it works

- Acts only on the workspace named **Vertical Workspace**. To use another name: `defaults write com.apple.FinalCut SpliceKitWorkspaceCollapseName "My Workspace"`.
- Uses Final Cut's own hide/unhide calls, so the menu items, shortcuts and workspace switching are unchanged.

## Requires

A custom workspace with the Browser and Inspector side by side above the timeline.

## Install

```sh
./install.sh workspace-collapse
```

Then restart Final Cut Pro. Remove with `./install.sh --uninstall workspace-collapse`. Log: `~/Library/Logs/SpliceKit/`.
