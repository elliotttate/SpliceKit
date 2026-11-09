# Grade Lock Skim

The second half of Grade Lock: locked clips are also ignored by the skimmer/playhead pick, so the **inspector shows the clip underneath** instead of the adjustment layer.

## Why

With nothing selected, Final Cut's inspector shows whatever is on top under the playhead, which on a finishing timeline is always the grade layer. You want to see the shot's own settings. This makes the inspector look *through* locked layers.

## How it works

- Skips locked clips in Final Cut's implicit (nothing-selected) selection and in the inspector.
- Picks the highest unlocked video clip under the skimmer or playhead.
- Hold **Option** to see the locked layer again.

## Requires

Grade Lock (same `lock` naming rule).

## Install

```sh
./install.sh grade-lock-skim
```

Then restart Final Cut Pro. Remove with `./install.sh --uninstall grade-lock-skim`. Log: `~/Library/Logs/SpliceKit/`.
