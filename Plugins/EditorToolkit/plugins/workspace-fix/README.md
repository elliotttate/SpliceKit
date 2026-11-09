# Workspace Fix

Removes SpliceKit's dual-timeline layout hooks that crash Final Cut when a custom workspace is applied.

## Why

On FCP 12.4 + SpliceKit 3.3.9, switching to a saved custom workspace crashed Final Cut. The cause was three of SpliceKit's dual-timeline layout swizzles. If you don't use the dual timeline, removing them is the quickest fix. This is a stopgap; the real fix belongs in SpliceKit's core.

## How it works

- Calls `SpliceKit_unswizzleMethod` for `LKModuleLayoutManager newExistingRegisteredModuleMatchingLayoutDictionary:`, `PEMediaBrowserContainerModule viewMinSize` and `FFContentBrowserModule constrainWidth:`.
- **Side effect:** the dual-timeline layout hooks are off while it's installed.

## Requires

SpliceKit (uses its exported unswizzle helper).

## Install

```sh
./install.sh workspace-fix
```

Then restart Final Cut Pro. Remove with `./install.sh --uninstall workspace-fix`. Log: `~/Library/Logs/SpliceKit/`.
