# RAW Gyro Presets

One-click gyro stabilisation for clips with gyro metadata: a **Gyro Preset** menu (Off / Smooth / Medium / Locked / Extra Strong) and a single **Gyro Strength** dial, added under *Gyroflow Stabilisation* in the RAW panel.

## Why

Blackmagic cameras record gyro data, and BRAW Toolbox exposes Gyroflow's controls (smoothness, adaptive zoom, zoom limit, horizon lock). Getting a good result means balancing four numbers on every clip. Resolve's Stabilizer has a single gyro mode with a strength value. These presets give the same one-decision workflow.

## How it works

- Pick a preset, or drag **Gyro Strength** (0 = off, 100 = strongest); all the Gyroflow controls move together.
- Applies to every selected clip at once.
- Styled to match the rows already in the panel.

## Requires

BRAW Toolbox's Gyroflow controls. Works in the RAW Tab or the original RAW panel.

## Install

```sh
./install.sh raw-gyro
```

Then restart Final Cut Pro. Remove with `./install.sh --uninstall raw-gyro`. Log: `~/Library/Logs/SpliceKit/`.
