# Registry and native integration contract

All shipped descriptors live in `mcp/splicekit_v4/capabilities/*.json` and validate
against `schemas/capability.schema.json`. The integrated catalog has 49 native
methods and four fixed Python handlers. Names and native methods are unique;
non-v4 native methods and nonlocal JSON Schema references are rejected. Descriptor
hashes cover both schemas and safety metadata. Restart invalidates discover/describe
grants. There is no schema alias conversion, raw RPC escape hatch or dynamic eval.

Descriptors require `name`, `description`, `input_schema`, `output_schema`, `backend`,
`undo_kind`, `readback_supported`, `evidence_level`, `requires_fcp_build`, and
`write_supported`. Exactly one of `method` or `local_handler` is present. Native
names equal their method names. Optional `operation_kind` distinguishes reads,
mutations and blocked local admissions: `write_supported:false` on analysis does
not mean its local admission bypasses the operation ledger. Category, atomicity,
read support and known limitations complete the discovery contract.

Native writes require caller-owned `operation_id` and `expected_revision` before
send. Optional `idempotency_key` is client correlation; native durable idempotency
uses `operation_id`. Native schemas accept executor control fields explicitly.
Nested v4 writes inherit the parent's ID, revision and outer undo group; they cannot
start an independent operation. The core performs the final revision check on main,
serializes native writes and persists operation records. Python's process lock and
cache do not replace that boundary. A no-op can conservatively invalidate the cheap
undo-epoch token; always use the returned revision for the next request.

All native receipts use `SpliceKitV4Result`; Python and live verification share
`envelope.py`. The ten base fields are always present, including nulls. Optional
`status` describes core pending/terminal state. Domain success readback schemas
must allow a pending envelope without inventing completed domain output. Native
`evidence_level` is `offline_tested`; registration is not live verification.

The only supported native CFBundleVersion is `454072` (FCP 12.4). Python discovery
may declare `*` for pure local work. `system.version` provides build identity for
execution; `v4.session.status` adds the native build policy, ledger and loaded-image
backing-file hash. Registry evidence caps returned receipts; it does not prove
picture, sound, native persistence or user acceptance.

## Implemented core bindings

| Bootstrap | Native method | Actual result |
| --- | --- | --- |
| `session_status` | `v4.session.status` | Native diagnostics, supported build, revision mode, modal state, ledger, image hash |
| `state_read` | `v4.state.revision` | Fresh session-scoped sequence concurrency token and diagnostics |
| `operation_status` | `v4.operation.status` | Ledger record in `readback.operation`, recorded envelope in `readback.result`, and `readback.state` |
| Checkpoint capability | `v4.history.checkpoint` | Observational state/history; no restorable checkpoint is promised |
| Owned single-edit undo | `v4.history.undo` | Checks target operation, current owning manager, unique top label and post-edit revision |
| Full semantic observation | `v4.state.snapshot` | Complete unfiltered native FCPXML under `readback.state.fcpxml` |

The Python UNKNOWN latch can clear only from a matching terminal native result with
a definite outcome and required fresh readback/revision. QUEUED/RUNNING/UNKNOWN
records do not clear it. `v4.operation.reconcile` never reapplies an edit; explicit
client evidence is marked as attestation rather than independent native proof.
Historical records survive restart; native undo ownership does not.

## Editorial and review boundary

EditPlan `args` are validated by their selected descriptor. Generic editorial
source/word timing remains `{num,den}`; native RPC time remains the exact declared
`{value,timescale,space}` form. Validation does not guess units or rename target
fields. Nested `target.clip_id` and cut left/right identities participate in scope
checks. The operation kind must match its capability family; history/control RPCs
cannot be smuggled into a parameter plan.

Pure validation and preview work with the merged descriptors. The compensated
executor additionally requires a native source/word/target state provider and an
owned, restorable checkpoint. Neither is supplied by the current native core.
`plan.apply` therefore rejects before sending a native write. Its functioning
checkpoint/restore path belongs to the isolated `examples/v4/fixtures` mock.
The bootstrap `history_checkpoint` also rejects missing project/sequence identity
rather than inventing that evidence; direct checkpoint discovery remains available.

Review additionally requires stopped playback, exact project-viewer identity,
render readiness, native playhead/frame rate and stable revision. These are not
attested by the current state probe, so native `review.capture` is fenced. Share
lacks a completed file/export job contract. These gaps remain explicit in
[README](README.md) and [UNVERIFIED](UNVERIFIED.md); no legacy fallback runs.
