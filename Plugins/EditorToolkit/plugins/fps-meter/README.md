# Playback Frame Rate

**View → Playback Frame Rate** shows a live readout in the viewer header: frames that actually reached the screen vs. the target rate, with skipped-frame detection.

## Why

When 6K BRAW with heavy effects stutters, Final Cut gives no number to go on, so it's hard to tell if a change (proxy, render, lower quality playback) helped. Resolve shows the playback FPS. This shows what was *delivered*, not an estimate.

## How it works

- Watches which frame the viewer's display actually draws on every refresh; a jump of *n* frame durations = *n−1* skipped frames.
- Target = the frame rate of what's playing (project or clip) × play speed.
- Hover for details: skipped frames in the last 3 s and this play, and the longest a frame stayed on screen.
- Turns itself off on Final Cut versions that don't have the internals it reads.

## Requires

Nothing.

## Install

```sh
./install.sh fps-meter
```

Then restart Final Cut Pro. Remove with `./install.sh --uninstall fps-meter`. Log: `~/Library/Logs/SpliceKit/`.
