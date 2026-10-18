# v4 tests workstream

This is the historical workstream report. [Integration README](README.md) and
[validation](VALIDATION.md) describe the final merged contract and current limits.

Branch: `v4/tests`. Base: upstream `223694a`. No FCP/SpliceKit process was launched,
no installed application was modified, and no upstream push/PR/comment was made.

## Delivered

- `make test` / `python3 -m tests.run`: FCP-free unittest runner, excluding the two
  legacy FCP/Apple Intelligence executable integration scripts. A Python override is
  available through `TEST_PYTHON`.
- `.github/workflows/v4-offline.yml`: macOS 14, Python 3.12, universal library build,
  and full offline tests. OTIO 0.18.1 is a wheel; the adapter is pinned to the exact
  bundled-fixture source commit and loaded through its manifest without installation.
- `tests/live/{rpc,contract,run_live}.py`: bounded newline TCP JSON-RPC, result-envelope
  validation, operation-owned undo, independent baseline/after/restore observations,
  exact rational fixture-rate and project/library identity gates, bridge-wide process
  lock, write-ahead quarantine, no-clobber raw proof, and scoped promotion candidates.
- `tests/live/v4/SCHEMA.md` and three mock-only example plans: parameter at 30 fps,
  rational trim at 30000/1001 fps, and explicitly blocked native analysis admission.
  Domain plans may choose `/revision_after` for the core's stamped read observations.
- `tests/live/mock_rpc.py` and `test_runner.py`: actual loopback TCP acceptance tests,
  including fragmented/unsolicited/stale frames, false embedded readback, changed
  revision, unknown acknowledgement, real socket timeout, partial/damaged undo,
  wrong library/path/project/rate, concurrent writer, retained evidence, quarantine,
  and mixed admission/mutation promotion boundaries.
- `tests/live/fixtures/`: original AVFoundation bars, seven-segment frame counter,
  and generated 440 Hz PCM tone; two exact-rate MOVs and library/project FCPXML
  blueprints with hashes; guarded import into an existing isolated test library;
  independent media inspection and offline generation tests. No ffmpeg or models.
- `tests/live/report.py`: reconstructs evidence levels from raw cycles and hashes,
  then generates `docs/v4/SUPPORT_MATRIX.md`. The initial matrix correctly has no
  capability evidence, because this wave did not run FCP.
- `CONTRIBUTING-v4.md`: proposed offline test + live plan + evidence requirements,
  separate static/host/perceptual/persistence gates, and explicit pending states.

## Design and acceptance boundaries

Every mutation cycle independently reads the declared semantic graph before/after,
checks the actual operation envelope, binds undo to the returned operation ID, and
compares the entire declared baseline projection after undo. Revision agreement is
required; neither a successful RPC nor its embedded readback is acceptance. Raw state
is retained, while comparison excludes only fields explicitly omitted by the domain
plan. Reviewers should require a sufficiently broad semantic comparison graph.

The library gate uses upstream `FFLibraryDocument.copyActiveLibraries`, count,
`displayName`, `URL.path`, and `timeline.getDetailedState`. Exactly one open library
must match the explicit canonical path and `SpliceKit-Test*` name/basename. Guards run
again throughout the cycle, including immediately before undo. They do not atomically
exclude a human or another generic bridge client; native revision checks and owned
undo must enforce that last boundary.

Unknown transport/host results are never replayed or blindly undone. A failed,
interrupted, or uncertain cycle leaves a quarantine file requiring explicit manual
reconciliation before another run in that evidence root. A settled apply with a wrong
readback attempts only its owned undo, preserving the original failed assertion.

Admission steps verify `applied=false`, `native_started=false`, `ready=false`, and
unchanged independent state/revision. They issue no undo. Mixed plans may promote
successful mutation capabilities, but blocked admissions remain `offline_tested` and
are listed separately in the candidate and matrix.

Live proofs bind the FCP build, reported runtime, fixture, plan hash, raw evidence
hash, and runner checkout. They do not attest the loaded binary hash. The perception,
save/reopen, and user-acceptance gates remain `not_checked`; native undo is not a
save/reopen or aesthetic guarantee. Mock proof cannot generate a promotion candidate.

## Small existing build/test fixes

The initial clean universal build failed its own undefined-symbol check without the
Blackmagic RAW SDK: `SpliceKit_bootstrapBRAWAtLaunchPhase` and
`SpliceKit_handleBRAWAVProbe` had no no-SDK definitions. The isolated
`Sources/SpliceKitV4BuildCompat.m` completes these fallbacks and has one canonical
`Sources/SOURCES.txt` entry. The SDK-present implementation and `SpliceKitServer.m`
are unchanged. The SDK-present branch was not tested on this machine.

Enabling optional OTIO regressions uncovered stale expected values: the package
contains four projects, not three; the pinned adapter maps the transition sample's
three ten-second clips to a 30-second OTIO timeline. Its source sequence duration
attribute is inconsistent with the spine; that attribute is not treated as native
acceptance. Counts, names, transitions, and durations remain asserted. Adapter source
provenance is recorded in `tests/fixtures/upstream_otio_fcpxml/README.md`.

## Validation

- `make -j2`: PASS, universal `arm64` + `x86_64`, no unresolved `SpliceKit_*` symbols.
  Existing BRAW pointer-alignment linker warnings remain; no deployment was run.
- Full offline suite with Python 3.12 + pinned OTIO adapter: 102 tests PASS, no skips.
- Runner-specific TCP/contract tests: 29 PASS. Default Python without OTIO explicitly
  skips the two optional upstream adapter tests.
- Generated media: 90 frames each, 360×640; every measured interval is exactly
  `1/30s` or `1001/30000s`; full durations 3 and 3.003 seconds; 144000/144144 PCM
  samples with RMS above 0.05. These are AVFoundation measurements, not FCP playback.
- `--check-plans`: all three templates PASS; the media workstream's external
  `media.json` also PASS (11 steps: five mutations, six admissions, `/revision_after`).
  That file remains owned by the media workstream and was not copied or edited.
- `git diff --check`: PASS. Workflow commands were exercised locally; the GitHub
  Actions service itself was not run from this branch.

## UNVERIFIED / next authorized live wave

No newly guessed native selectors or `// UNVERIFIED` native calls were introduced.
The example v4 method names are mock-only templates and not registrations.

1. Bootstrap the native test library from the FCPXML blueprint, import both variants,
   and verify the exact native project/library identities. The generator does not
   fabricate a native `.fcpbundle`; upstream `project.createLibrary` only opens a dialog.
2. On the actual FCP build, prove each registered domain's independent readback,
   revision precondition, operation ownership, and full undo restoration. Replace
   template targets and remove `template: true` only when those fixture identities exist.
3. Reconcile any unknown operation using host status, then add separate picture/audio
   review and native save/reopen tests where the capability needs them. Attach loaded
   binary provenance before making a broader compatibility claim.

## Suggested upstream PR split

1. Standalone clean-build no-SDK BRAW fallback fix.
2. Offline runner, optional OTIO fixture corrections/provenance, and macOS CI.
3. Live plan/envelope contract, guarded runner/mock RPC, proof/promotion reporting.
4. Original generated fixtures, guarded installer, contribution draft, and workstream
   documentation. Domain implementations/plans remain separate contributions.
