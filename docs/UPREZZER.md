# Uprezzer

Uprezzer is a SpliceKit add-on for Final Cut Pro that turns selected clips into higher-resolution versions without leaving the edit flow.

## Why it exists

Editors already have the shot, the timing, and the context inside Final Cut Pro. Uprezzer keeps that context intact while doing the upscaling locally with `fx-upscale`.

## What it does

- Works from either timeline selection or browser selection
- Supports only `2x`, `3x`, and `4x` scale factors
- Validates that source media is file-backed before processing
- Runs `fx-upscale` locally with computed output dimensions
- Imports the finished file back into Final Cut Pro
- Optionally replaces the selected timeline clip after import
- Writes logs and a JSON report for each job under `~/Movies/Uprezzer/Jobs/<job-id>/`

## Launch points

- `Enhancements > Uprezzer`
- Command Palette: `Uprezzer`

## Dependency

Uprezzer expects `fx-upscale` to be installed locally. It looks for:

- `/opt/homebrew/bin/fx-upscale`
- `/usr/local/bin/fx-upscale`
- `/usr/bin/fx-upscale`

If the binary is missing, the panel disables the run button and shows a clear inline message.

## Output behavior

- Original source media is never overwritten in place
- Each run stages files in its own job directory first
- Imported clips use names like `Clip Name [Uprezzer 2x]`
- Browser/library replacement stays conservative in v1
- Timeline replacement falls back to import-only reporting if Final Cut does not accept the replace action safely

## Managed workspace

Every run gets a dedicated job folder:

`~/Movies/Uprezzer/Jobs/<job-id>/`

Subfolders:

- `logs/`
- `renders/`
- `reports/`

## Scope

Supported in this pass:

- Timeline selection
- Browser selection
- Batch handling
- Local `fx-upscale` invocation
- Import back into Final Cut Pro
- Optional timeline replacement
- Progress and result reporting

Intentionally deferred:

- Arbitrary custom output dimensions
- Browser-level destructive replacement
- Bundled `fx-upscale` shipping
- Persistent queue resume across relaunch
- Perfect edge-case handling for every compound or multicam scenario
