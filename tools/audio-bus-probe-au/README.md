# SpliceKit Audio Bus Probe AU

`SpliceKitAudioBusProbe.component` is a small AUv2 pass-through effect for audio bus testing in Final Cut Pro.

It does not alter audio. It reports whether render callbacks are receiving non-silent input, plus input peak/RMS, render count, render timing, CPU load estimate, frame counts, channel count, and the last render error.

Build and install:

```bash
make install-audio-bus-probe
```

After install, restart Final Cut Pro if the effect is not visible yet. The effect appears as:

```text
SpliceKit: Audio Bus Probe
```

Runtime status is written outside the real-time render thread:

```bash
tools/audio-bus-probe-au/read_probe.py
```

FCP may create several AU instances while scanning, previewing, and rendering. The reader picks the instance with the most render activity by default; use `--all` to list every instance.

The raw latest-status file is `/tmp/splicekit-audio-bus-probe-latest.json`; each instance also writes `/tmp/splicekit-audio-bus-probe-<pid>-<instance>.json`.
