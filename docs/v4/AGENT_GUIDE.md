# SpliceKit v4 agent guide

Start with **seven tools**. Detailed editing schemas are discovered on demand.

Integrated beta: 49 native RPCs plus four Python capabilities are discoverable.
Direct typed domain edits and owned single-operation undo are implemented. Native
`plan.apply` and `review.capture` remain fenced because restorable checkpoints,
source/word state and attested viewer readiness are absent. The compensation and
review flow described below is demonstrated by the offline fixture only; see
[the integrated contract](REGISTRY_CONTRACT.md) before attempting live work.

```sh
python -m pip install -r mcp/requirements.txt
SPLICEKIT_TOOLSET=v4 python mcp/server.py
```

`legacy` (default) keeps the original tools, resources, prompts and plugin discovery.
`v4` exposes only the bootstrap below, with no startup RPC, legacy prompts, plugin
registration, Lua, raw RPC, ObjC evaluation, deployment or unrestricted execution.
`all` exposes both catalogs for migration; it includes the legacy execution tools.

| Step | Call | Read before proceeding |
| --- | --- | --- |
| Bootstrap | `session_status()` → `state_read()` | Host build, session-scoped revision and diagnostics; source/viewer evidence is not supplied. |
| Find | `capability_search(query, category, limit=10)` | Name, backend, schema hash, exact supported builds, evidence, limitations. |
| Explain | `capability_describe(name)` | Full input/output schemas, undo/readback contract. Search must precede describe. |
| Invoke | `capability_invoke(name, arguments, schema_hash)` | Use the described hash; parameters are validated before dispatch. |
| Verify | Read the result envelope and fresh native state | `ok` requires readback for writes. Visual/audio acceptance is separate. |

For editorial work, discover `plan.validate`, `plan.preview_diff`, `plan.apply` and
`review.capture`, then invoke them through `capability_invoke`. The first two take
`{"plan": EditPlan}`; apply also requires `idempotency_key`. Capture takes
`{"request": ReviewRequest}`. The machine-readable schemas are in
[`mcp/splicekit_v4/schemas`](../../mcp/splicekit_v4/schemas).

EditPlan operations are ordered cuts, titles, effects, parameters or transitions.
A cut carries source ID, source time range and contiguous transcript word IDs.
Use rational seconds `{num, den}`, half-open ranges, and the source's frame rate;
`snap_words()` rounds word starts down and word ends up to the source frame grid.
Model video timestamps alone are insufficient. Examples:
[`edit-plan.json`](../../examples/v4/fixtures/edit-plan.json),
[`gemini_edit_loop.py`](../../examples/v4/gemini_edit_loop.py).

Apply validates every step before checkpointing, compares source/word evidence
with fresh native state, and chains each native revision into the next step.
A confirmed failure restores only the owned checkpoint, with native baseline
readback. A timeout or missing readback produces `UNKNOWN_OUTCOME`, blocks writes,
and defers restoration. Use `operation_status(operation_id)` to inspect the native
ledger; never replay a write or issue a blind undo. Only a terminal, matching native result with a definite outcome and required
readback/revision can clear a session's unknown latch. Python caches
are session-local; cross-client single-writer ownership, restart reconciliation,
atomic revision checks and durable idempotency are the native core's responsibility.

`history_checkpoint(label, project_id, sequence_id, expected_revision)` requests a
native checkpoint. The integrated bootstrap rejects missing identity evidence;
direct `v4.history.checkpoint` returns observational history only. A label alone
does not establish restorability. Missing core
capabilities return `UNSUPPORTED_CAPABILITY`; no legacy fallback runs.

`review.capture` currently supports a stopped, rendered **project viewer frame**,
with before/after native identity, frame time, file SHA-256 and metadata binding
hash. Actual coverage is one frame; requested context range is recorded separately.
It has no audio or motion evidence. `native_share` returns
`NATIVE_SHARE_UNVERIFIED`: the existing `share.export` only starts a share flow.
See [the native review contract](NATIVE_REVIEW.md) before implementing video review.

Evidence progresses `static → offline_tested → live_verified → production`, scoped
to a capability and exact FCP build. Discovery grants no execution permission;
static-only native capabilities cannot execute. Offline tests never establish
live readback, appearance, audio, persistence or user acceptance.

```sh
# No credentials, model/network calls, FCP launch or native RPC:
python examples/v4/gemini_edit_loop.py --dry-run
# Future integration only: requires implemented state and checkpoint restore bindings:
GEMINI_MODEL=<video-capable-model-id> python examples/v4/gemini_edit_loop.py \
  --live --media /absolute/path/to/short-source.mp4
```

The live example reads `GEMINI_API_KEY` only from the environment. The model ID is
supplied by the caller. It makes separate planning and critique calls and applies
only revision-bound corrections using available capabilities. The bounded loop
reports remaining issues and leaves audio/motion/user acceptance open.
