# Grade Lock

Clips with **lock** in their name can't be selected on the timeline unless you hold **Option** while clicking.

## Why

A finishing timeline for fashion and commercial work stacks adjustment layers on top of everything: grade, film emulation, grain, letterbox. Those layers sit above the footage, so clicks and marquee drags keep grabbing them by accident. Final Cut has no per-clip lock. Renaming a layer to include "lock" is the simplest switch that works without any UI.

## How it works

- Name a clip or adjustment layer e.g. `GRADE lock`, `lock - grain`.
- Clicks and drag-selections skip it; **Option-click** still selects it.
- Matching is case-insensitive and anywhere in the name, so a clip called *Clock tower* also counts. Rename such clips if needed.

## Requires

Nothing. Pair with **Grade Lock Skim**.

## Install

```sh
./install.sh grade-lock
```

Then restart Final Cut Pro. Remove with `./install.sh --uninstall grade-lock`. Log: `~/Library/Logs/SpliceKit/`.
