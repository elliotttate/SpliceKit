# Batch Sync Audio

**Clip → Batch Sync Audio…** syncs many video clips with external audio recordings at once by waveform. Each video becomes a native **Synchronized Clip** playing the external audio.

## Why

Final Cut's Synchronize Clips works on one video and one recording at a time, and it needs both in the browser. A shoot day with a separate recorder (DJI Mic, Zoom) can mean dozens of takes. Tools like PluralEyes or Syncaila handle this outside the app. This does it inside Final Cut, right on the timeline.

## How it works

- Select the video clips on the timeline plus the recordings (in the browser and/or audio-only clips on the timeline) and run the command.
- Every camera track is compared with every recording, so you don't need to pair them up first.
- Engine (Apple Accelerate/AVFoundation only, no third-party code): an onset-envelope FFT cross-correlation finds the right recording and coarse offset, then GCC-PHAT refines it to sub-sample accuracy. Corrects AVFoundation's sample-rate drift on long recordings.
- A review panel shows each match with a confidence score; low confidence is flagged.
- Each timeline clip is swapped for its Synchronized Clip in the same place with the same in/out and attributes. Camera audio is kept but switched off. One undo step.
- Clips with a speed change are left as they are.

## Requires

Nothing.

## Install

```sh
./install.sh audio-sync
```

Then restart Final Cut Pro. Remove with `./install.sh --uninstall audio-sync`. Log: `~/Library/Logs/SpliceKit/`.
