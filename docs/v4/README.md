# SpliceKit v4 beta integration

V4 adds a discoverable, typed operation boundary around native Final Cut Pro edits.
The integrated catalog contains **49 native RPCs and 4 Python capabilities**. The
package version stays **3.3.9**; this branch proposes `4.0.0-beta` behavior without
changing release packaging. The initial integration was offline. The authorized
2026-10-18 live attempt deployed to the patched copy and stopped before editing:
native XML bookmarks changed across identical observations. **0/46 suite steps
passed; 46 remain blocked, and no capability is live_verified.** Session contract
fixes were retested on FCP 12.4. See [LIVE_REPORT](LIVE_REPORT.md) for evidence,
library restoration limits, remaining gates and rollback commands.

## Architecture

Seven MCP bootstrap tools expose session status, capability search/describe/invoke,
state reads, operation status and checkpoints. The registry is the only discovery
catalog: each registered `v4.*` native RPC has exactly one descriptor, and every
native descriptor has a compiled registration. A macOS offline test links all
production v4 translation units and checks this bijection, mutation metadata,
supported build, input contract and evidence level.

Native routing enters the core before legacy dialog dismissal, asynchronous dispatch
or error conversion. The durable JSONL ledger reserves a caller-owned operation ID;
one writer executes synchronous handlers on the main run loop. A repeated ID with
the same arguments returns its recorded result; changed arguments conflict. Pending
or UNKNOWN outcomes are observed through `v4.operation.status`, never replayed with
a new ID. Restarts preserve records but invalidate native undo ownership.

Every top-level mutation requires `operation_id` and `expected_revision`. The native
revision is a session-scoped undo-epoch concurrency token, not a content hash. Native
notification coverage remains a live gate. Empty/failed native groups may invalidate
it conservatively, so a no-op's fresh token can differ. Always chain the returned
revision. Domain-specific native action/undo transactions register their inverses
inside one core-owned outer NSUndoManager group. A missing inverse reports unknown
undo ownership. `v4.history.undo` consumes only its target's unchanged top group;
it does not create a second synthetic editing group. Blocked analysis admission and
its local cancellation do not change native content and intentionally have no undo.

All handlers use `SpliceKitV4Result`. Python adapters and the live runner share
`envelope.py`; the registry result schema is checked against that source. Success
keeps `error: null` inside the JSON-RPC result. Each result carries application
certainty, readback, before/after revisions, undo ownership and evidence. The only
supported native build is FCP **12.4 (454072)**, with `offline_tested` evidence.

| Native area | RPC count | Scope |
| --- | ---: | --- |
| Core | 7 | Session/build, revision, full native XML snapshot, checkpoint, operation status/reconcile, owned undo |
| Parameters/effects | 13 | Exact effect instances, typed channel tree, values and scalar keyframes |
| Titles/captions/transitions/generators | 11 | Explicit native identities, text fields/spans, rational timing, connected insertion |
| Media | 18 | Color bindings, audio, retime and blocked analysis admission/status/cancellation |

`v4.state.snapshot` uses the existing native FCPXML exporter and retains the complete
unfiltered XML in `readback.state.fcpxml`. This supplies independent whole-project
comparison for insertion/removal and undo tests. It removes its private temporary
file, rejects snapshots over 8 MiB, and makes no claim of visual/audio equivalence.

## Try it offline

```sh
python3.12 -m venv build/v4-venv
build/v4-venv/bin/python -m pip install -r tests/requirements-offline.txt -r mcp/requirements.txt
git clone --no-checkout https://github.com/OpenTimelineIO/otio-fcpx-xml-adapter.git build/otio-fixture-adapter
git -C build/otio-fixture-adapter checkout 20d9fa54141149c09d976f3520a8c29d8e5ad124
make -j2
make test TEST_PYTHON=build/v4-venv/bin/python
build/v4-venv/bin/python -m tests.live.run_live --check-plans
build/v4-venv/bin/python examples/v4/gemini_edit_loop.py --dry-run
```

For the two optional OTIO fixture tests, CI checks out adapter commit
`20d9fa54141149c09d976f3520a8c29d8e5ad124` into `build/otio-fixture-adapter` and sets
`OTIO_PLUGIN_MANIFEST_PATH` to its `src/otio_fcpxml_adapter/plugin_manifest.json`,
with `OTIO_DISABLE_ENTRYPOINTS_PLUGINS=1`. See [validation](VALIDATION.md) for exact
results and the separately reproduced Python 3.14 upstream dependency failure.
`tests.run` blocks production bridge port 9876 and external connections while
allowing the loopback mock servers. The workflow never deploys or launches FCP.

## Choose legacy or v4 tools

```sh
# Original catalog, resources, prompts and plugin discovery (default):
SPLICEKIT_TOOLSET=legacy build/v4-venv/bin/python mcp/server.py
# Seven bootstrap tools, typed discovery, no startup native RPC:
SPLICEKIT_TOOLSET=v4 build/v4-venv/bin/python mcp/server.py
# Both surfaces for migration:
SPLICEKIT_TOOLSET=all build/v4-venv/bin/python mcp/server.py
```

In v4, search for `v4.parameter.set`, describe the result, then invoke its exact schema
hash. Copy native `clip_id`, effect `fileUUID` and numeric channel paths from the
fixture's readback; display names, array positions and runtime handles are not
substitutes. Obtain a fresh token from `state_read()` (`v4.state.revision`) and create
an operation UUID before dispatch. A distinct optional `idempotency_key` is client
correlation; the native durable identity is `operation_id`.

Pure EditPlan validation/diff accepts native descriptor arguments and checks nested
target scope. **Native multi-step `plan.apply` is fenced:** core checkpoints are
observational and there is no native `history.restore` or transcript/source-state
provider. The fixture's compensated executor is an offline example, not a native
capability. Native `review.capture` is also fenced until project-viewer identity and
readiness are attested by a state provider; native Share lacks a completed export
contract. Direct discovered domain operations and owned single-operation undo are
the implemented native editing route. Analysis adapters explicitly report blocked
admission; they do not execute tracking/masks/stabilization.

## Live verification handoff

The default suite in `tests/live/v4-suite.json` runs **46 steps** in one order:
14 reads, 1 core contract cycle, 11 params cycles, 9 titles cycles, then 5 media
cycles and 6 blocked admissions. Every mutation observes complete native XML before,
after and after owned undo; domain-specific checks are retained separately.

All integration plans remain `template: true`. The designated live operator must
prepare the single disposable 30fps fixture, bind every real identity/path/role,
prove repeated XML stability, and remove each fence explicitly. Only then:

```sh
python -m tests.live.run_live --live --library-path /absolute/path/SpliceKit-Test-v4.fcpbundle
```

The runner never launches FCP, installs a dylib, imports a project or closes a
library. It verifies exactly one open fixture library and exact project/rate before
observations and writes. Unknown/failed cycles leave a durable quarantine latch.
The three `example-*` plans are mock-only and excluded from the default suite.
Restart/modal/manual-history cases remain explicit manual gates in the plans.
See [live schema](../../tests/live/v4/SCHEMA.md), [unverified boundaries](UNVERIFIED.md),
[validation](VALIDATION.md), and [upstream PR sequence](PR_PLAN.md).
