# Integration validation, 2026-10-18

## Subsequent authorized live attempt

See [LIVE_REPORT](LIVE_REPORT.md) for the later deployment to the patched copy,
three defect fixes, 173/173 Python 3.12 offline result, and loaded-binary readback.
The independent XML baseline preflight failed on changing native bookmark data;
0/46 suite steps passed and all domain mutation/undo cycles remain unverified.
The original offline checkpoint below is historical, not a statement that no
later deployment occurred. No upstream push or PR was made.

## Initial offline integration checkpoint

Scope: `v4/integration`, upstream base `223694a`, all six workstreams merged.
Implementation finalized in `d2ff1e6`, `71f812c`, `0814bdd`, and `5aab936` after
core merge `8398942`. Tests used that source content; final documentation does not
change executable behavior. No installed application write, FCP launch, deploy,
import, model call, upstream push or PR occurred. Version.xcconfig remains 3.3.9.

| Check | Result |
| --- | --- |
| `make -j2` | PASS, universal x86_64 and arm64 dylib |
| Undefined internal SpliceKit symbols | None (`nm -u build/SpliceKit`) |
| Supplied Python 3.14.8 environment, `python -m tests.run` | 171 tests: 169 PASS, 2 OTIO dependency errors; no skips |
| CI-equivalent Python 3.12.13 + pinned adapter | 171/171 PASS; no skips |
| Actual native registry vs descriptors | 49/49 RPCs, bijective; 53 total capabilities including Python |
| Native core/params/titles/media harnesses | 202 / 131 / 580 / 72 checks, all PASS |
| All live JSON plans | 8/8 validator PASS; no connection |
| Default sequential suite | 46 steps: 14 reads, 26 native mutation/owned-undo cycles, 6 blocked admissions |
| Gemini example `--dry-run` | PASS, two synthetic mock rounds; no network/model/native call |

The generated `build/SpliceKit` SHA-256 was
`c694f53ba99573a5701f96672031f9507788a676b67412b8e5340bc0fff7eeed`.
This identifies the local built artifact only; debug paths/toolchain make builds
non-reproducible across machines. It does not identify a loaded FCP image.
Existing BRAW decoder pointer-alignment linker warnings remain. Architecture
presence does not prove live execution on both architectures.

## Supplied environment and unchanged upstream control

```sh
/tmp/sk4-venv/bin/python -m tests.run
/tmp/sk4-venv/bin/python -m tests.verify_otio_upstream --upstream 223694a
```

Both runs retain these two errors:

- `OTIOUpstreamFixtureTests.test_fcpxmld_package_fixture_reads_via_info_entrypoint`
- `OTIOUpstreamFixtureTests.test_transition_fixture_reads_with_adapter_fallback`

Exact shared error:
`No working FCPXML adapter found (fcpxml: bad any cast; fcpx_xml: bad any cast)`.
The control compiles untouched `223694a:mcp/server.py` with the same interpreter,
dependencies and current fixture assertions. Native/network access is blocked.
It is read-only and does not check out or edit an upstream worktree. The control
runs two tests and exposes both errors with a failing exit status; it does not
skip or relabel them as expected failures. The integration leaves OTIO helpers,
fixtures and assertions unchanged from the merged tests branch.

This is the supplied Python 3.14/OTIO binary dependency failure, distinct from
the older workstream report's adapter/assertion investigation. Python 3.12 with
the exact fixture adapter passes both current fixture tests. CI installs both
`tests/requirements-offline.txt` and `mcp/requirements.txt`, uses OTIO 0.18.1, and
loads adapter `20d9fa54141149c09d976f3520a8c29d8e5ad124` through its manifest.

The local CI-equivalent run reused an existing read-only Python 3.12 environment
and pinned adapter from the agent worktree. It ran this integration checkout's
suite, not that worktree's tests, with bytecode writes disabled:

```sh
PYTHONDONTWRITEBYTECODE=1 \
OTIO_PLUGIN_MANIFEST_PATH=/absolute/path/to/otio-fcpx-xml-adapter/src/otio_fcpxml_adapter/plugin_manifest.json \
OTIO_DISABLE_ENTRYPOINTS_PLUGINS=1 \
/path/to/python3.12 -m tests.run
```

Local raw logs, dry-run output and the actual compiled registration map are retained
under ignored `build/v4-integration/`. Committed tests and commands reproduce the
checks; local logs are supporting evidence, not portable live receipts.

## Gates still open

All 49 native capabilities remain `offline_tested`. Live plans remain templates.
Native transaction nesting/undo restoration, manual-edit notification coverage,
XML stability, identity durability, calibrated units/time mapping, output picture
and sound, native save/reopen and user acceptance are unperformed. Native analysis
execution, multi-step checkpoint restore/source-state and attested viewer review
are explicitly unavailable. See [UNVERIFIED](UNVERIFIED.md).
