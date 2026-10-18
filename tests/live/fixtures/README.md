# Disposable v4 fixtures

Generate a fresh library/project FCPXML blueprint and original, redistributable media:

```sh
python3 -m tests.live.fixtures.prepare --output build/v4-fixtures
```

Requires macOS 14+ and Command Line Tools. Each MOV contains 90 H.264 frames at
360×640, eight color bars, an increasing frame counter, and a generated 440 Hz mono
PCM tone with second pulses. Both exact frame durations (`1/30s`, `1001/30000s`) are
produced; durations are 3 and 3.003 seconds. AVFoundation creates the image stream and
muxes the original tone. No ffmpeg, recording, external assets, speech, or model calls.
`--xml-only` creates blueprint references without media and is never importable.

`manifest.json` records generated filenames, media/XML SHA-256, generator hash,
library path, project names, and rational rates. The library location in each FCPXML
describes `SpliceKit-Test-v4.fcpbundle`; generating XML does **not** create a native
FCP bundle. In the authorized live wave, bootstrap that disposable library in FCP
from the blueprint (or create the empty test library at the chosen path), close every
other library, then import the projects through the guarded installer:

```sh
python3 -m tests.live.fixtures.install build/v4-fixtures/manifest.json \
  --library-path /absolute/path/SpliceKit-Test-v4.fcpbundle
```

The installer verifies media/XML hashes, requires exactly one open test library,
checks its canonical path, and uses internal `fcpxml.import` with file fallback
disabled. It never invokes `newLibrary:` (upstream exposes a dialog, not a typed
library constructor), starts FCP, or closes another library. The acknowledgement is
stored separately from project readback. Bootstrap/import/native project availability
remain a live acceptance check. Open the exact project before running its plan.

For independent media checks, compile `inspect_media.swift` with `swiftc`; its JSON
reports decoded PCM RMS/sample count, video dimensions, presentation intervals,
duration, and frame count. `make test` generates both variants in a temporary directory
and checks these measurements without FCP. These measurements do not establish native
FCP playback or subjective audiovisual acceptance.

The Swift fixture source and the pixels/audio it generates are original repository
test assets under the repository license. The counter uses drawn seven-segment digits;
there are no font files or WindowServer dependencies.

`advanced.blueprint()` builds the live fixture from an original 30-second stereo
MOV (generator optional arguments: `30 1 900 2`). It includes a 10-second source
trim, two Gaussian instances, Letterbox, Colorize, transform keys, editable title,
English/Turkish captions, Music audio role, a clean cut and a separate existing
transition. Captions use native lane 1: FCP canonicalizes imported lane 2 during
transaction closure, which is a real state difference and is never filtered.
Bind native persistent IDs and parameter paths after import; no placeholder ID is
accepted as live evidence. Colorize's RGB control has implicit alpha 1; arbitrary
alpha changes must be rejected. Keep every raw XML export.
