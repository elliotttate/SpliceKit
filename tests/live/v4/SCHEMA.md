# Live verification plan contract, version 1

Plans are JSON objects validated by `tests/live/contract.py`. Validation is dependency
free. Run `python3 -m tests.live.run_live --check-plans` before submitting a plan.
The three `example-*.json` files are executable **mock-only templates**, not claims that
the proposed RPC methods exist. Domain authors must replace the calls with their
registered methods and remove `"template": true` before real verification.

## Plan fields

| Field | Required | Meaning |
| --- | --- | --- |
| `schema` | yes | Exactly `splicekit.live-plan/1` |
| `id` | yes | Unique filename-safe identifier, 1–80 ASCII letters/digits/`_`/`-` |
| `template` | no | Boolean; true fences a sample out of live execution |
| `description` | no | Human-readable scope and limitations |
| `fixture.library_name` | yes | Exact open library display name, starts with `SpliceKit-Test` |
| `fixture.project` | yes | Exact already-open project name, starts with `SpliceKit-Test` |
| `fixture.frame_duration` | yes | `1/30s` or `1001/30000s`; verified as a rational host value |
| `steps` | yes | Nonempty array of independent apply/readback/undo cycles |

Each step has a unique string `id`, a registry `capability` name, and these objects:

| Object | Fields |
| --- | --- |
| `apply` | `method` (registered `v4.*` mutation), `params` (object) |
| `readback` | `method` (different independent observation RPC), `params`, `expect`, `compare`, optional `revision` |
| `undo` | `method` (registered `v4.*` owned undo), `params.operation_id` must be `{"$ref":"/apply/operation_id"}` |

Steps default to `"kind": "mutation"`. For a blocked, unimplemented native analysis
admission use `"kind": "admission"`, omit `undo`, and add `apply.expect`, a JSON-pointer
mapping that explicitly expects `/applied: false`, a `native_started` flag of false,
and a `ready` flag of false at their actual envelope paths. For example:

```json
{"/ok": false, "/applied": false, "/readback/native_started": false,
 "/readback/ready": false, "/error/code": "NOT_IMPLEMENTED"}
```

Its independent readback must equal the entire declared baseline projection and keep
the same revision; a convenient expectation is `{"/state":{"$ref":"/baseline/state"}}`.
The envelope must declare `undo.kind: none`. No undo request is sent. A passing
admission plan proves blocked admission and unchanged state, **never implemented
native analysis**. Admission steps stay `offline_tested`, even when run against FCP.
Mixed plans are supported: only successful mutation steps can appear in the promotion
candidate; admissions are listed separately as `blocked_admissions` and are never
promoted. An admission-only plan produces no promotion candidate. See
`example-admission-30.json`.

`readback.expect` is a nonempty mapping from RFC 6901 JSON pointers to expected JSON
values. Comparison is exact and type-sensitive, including false versus zero.
`readback.compare` is a nonempty array of pointers selecting the **complete semantic
state** that undo must restore. Every expected pointer must fall within this projection.
Prefer a whole semantic graph such as `/state` over a single changed leaf, so unrelated
clip/effect damage is detected. Retain raw responses; never strip a volatile field
without a measured, documented reason. `readback.revision` defaults to `/revision`.
The independent revision must equal apply's `revision_before` before the write and
`revision_after` after it. Revision drift halts the run without blind undo.

Parameter values can be literal JSON or `{"$ref":"/fixture/project"}` style references.
References use JSON pointers into `{fixture, baseline, apply, after}` as available at
that stage; an unavailable reference fails closed. `expect` can reference the fixture
or baseline. Readback parameters must be stable between baseline/after/restore.
Undo should also bind `expected_revision` to `{"$ref":"/apply/revision_after"}` if its
backend supports revision preconditions. A generic `timeline.action` undo is rejected.

Apply and undo must return the complete shared v4 envelope:

```json
{
  "ok": true, "operation_id": "host-owned-operation", "applied": true,
  "readback": {}, "revision_before": "r1", "revision_after": "r2",
  "undo": {"kind": "native_group", "label": "Fixture edit"},
  "evidence_level": "offline_tested", "warnings": [], "error": null
}
```

Embedded readback is recorded but does not count as independent verification. Apply
must declare `native_group` ownership and produce an observable semantic change.
Both envelope and fresh readback revisions must agree. Restore is compared by semantic
SHA-256 projection; raw state and raw wire responses remain in the evidence.

## Execution and safety

```sh
python3 -m tests.live.run_live --live tests/live/v4/my-domain.json \
  --library-path /absolute/path/SpliceKit-Test-v4.fcpbundle
```

The runner connects only to an already-running loopback TCP bridge (default 9876).
It never starts FCP, installs a binary, imports a project, closes a production library,
or changes the active project. Before every mutation and observation phase it queries
`FFLibraryDocument.copyActiveLibraries`, count, exact `displayName`, `URL.path`, active
project name, and rational frame duration. Exactly one library must be open. Both its
display name and bundle basename must begin `SpliceKit-Test`; its canonical path must
equal the explicitly supplied absolute path. Probe handles alone are released.

The bridge-wide file lock excludes other runner processes, including other worktrees.
The host must be quiescent: this client cannot atomically exclude a human or another
arbitrary bridge client. Native revision preconditions and owned undo remain essential.
Any timeout/connection loss after send is **unknown**. No write is retried and no
generic undo is attempted. A write-ahead `.quarantine-<port>.json` in the evidence root
survives interrupted or failed cycles and blocks subsequent runs. Reconcile host
operation status and baseline manually, retain the failed evidence, then remove this
latch explicitly. A readback mismatch after a settled write still attempts its owned
undo; the failed assertion is retained even if restore passes.

## Evidence and registry integration

The CLI writes `evidence/YYYY-MM-DD/<plan>.json` using UTC dates and no-clobber atomic
publication. Same-day repeats receive a run UUID suffix. The proof includes the plan
and its hash, runtime FCP/build/macOS/architecture, source commit/dirty state, operation
envelopes, independent baseline/after/restored responses, and RPC transcript.

Separate gate fields are `static`, `host_readback`, `perceptual`, `native_undo_restore`,
`save_reopen`, and `user_acceptance`. Unperformed checks are `not_checked`. This runner
does not infer picture, audio, save/reopen durability, or aesthetic acceptance.

Only a successful `--live` run writes `<plan>.promotion.json`, schema
`splicekit.capability-evidence/1`. It contains the capability names and proposed
`evidence_level: live_verified`, evidence SHA-256 (canonical JSON), plan hash, exact
runtime/build, fixture, and scope `host_readback` + `native_undo_restore`. The registry
consumer should verify these hashes and preserve the build/scope binding; merge the
candidate during review rather than editing the registry at test time. The runner
does not claim to have attested the loaded binary hash; runtime version comes from
the host and source commit is the runner checkout. Attach binary provenance separately
before making a broader compatibility claim.

`--mock` refuses port 9876, marks host gates `simulated`, never exceeds
`offline_tested`, and never writes a promotion candidate. A simulated version response
is rejected in `--live` mode. Generate the support matrix with:

```sh
python3 -m tests.live.report
```

## Integrated sequential suite

`tests/live/v4-suite.json` is the default order for execution:
`agent.json` (14 read-only observations), `core.json` (1 ledger/replay/revision/owned
undo cycle), `params.json` (11 cycles), `titles.json` (9 cycles), then `media.json`
(5 mutations and 6 blocked admissions). This is **46 top-level steps**, including
26 apply/readback/undo cycles. The three `example-*` plans stay mock-only and are
excluded from this default suite. `--check-plans` validates all eight JSON plans.
All five integration plans remain templates until an operator binds the native
fixture IDs and deliberately removes each `template` fence. Use the same exact
library/project/rate throughout; preparation is described in `fixture_setup`.
`manual_cases` retains the workstreams' additional runtime/perceptual/restart cases;
those prose instructions are not executed or counted as automated steps.

The contract additionally supports `kind: read` and `kind: rejection`. Both omit
undo, explicitly assert `/applied: false`, and compare the independent full semantic
baseline and revision unchanged. A read may apply and observe the same registered
read RPC. Rejection steps explicitly assert the expected native error. They cannot
promote mutation/undo evidence. Admissions keep the stricter native_started/ready
requirements above. Read-only and admission-only runs stay `offline_tested`.

Each step gets fresh `/run/operation_id` and `/run/check_operation_id` UUIDs before
send. Integrated writes explicitly bind `operation_id` to the first UUID and
`expected_revision` to `/baseline/revision_after`. The raw resolved `apply_request`
is retained in evidence. Optional `after_apply` calls have `method`, object `params`
and nonempty JSON-pointer `expect`; they can reference `/apply`, `/apply_request`,
`/baseline`, `/fixture` and `/run`. Core's exact-ID replay is deliberate and runs
only after the first write has settled. No timeout is replayed. These assertions
are recorded and rechecked by the evidence reporter. A failed assertion after a
settled edit still attempts only that edit's owned undo.

Every integrated mutation compares `/readback/state` from `v4.state.snapshot`.
This is the complete unfiltered FCPXML returned by the existing native exporter,
not a target-local projection. Its private temporary file is removed after read;
exports larger than 8 MiB fail explicitly. Repeated baseline exports and post-undo
XML must match exactly. Export identity/metadata instability is a failed gate;
no field is removed to manufacture equality. Domain readback checks additionally
verify parameters/effect inventories/title fields/audio/retime where available.
The snapshot introduces no new private selector; runtime export/undo stability
still requires the live fixture.

Before each apply, the runner now reads the independent baseline twice under the
same library/project guard. The full comparison projection and revision must
match. `baseline_confirmation` retains the second raw response, with both hashes;
an unstable baseline stops before dispatch and never triggers undo. The evidence
reporter rechecks this confirmation before accepting live promotion. Random native
bookmark data is an observation failure, not permission to remove XML fields.

## Native XML comparison: exact except security-scoped bookmark bytes

`v4.state.snapshot` retains the original UTF-8 export in `readback.raw_fcpxml`.
`readback.state.fcpxml` removes only base64 text inside `<bookmark>` elements.
No IDs, timestamps, attributes, whitespace outside bookmark payloads, element order,
or other fields are normalized. Unexpected bookmark encoding fails closed.
These macOS security-scoped access bytes are not project state; round 1 measured
1,020 decoded bytes with changes confined to offsets 16-47 on repeated exports.
`readback.state.asset_identity` separately records each resource asset's ID, exact
source URLs, duration and format ID. All are included in baseline/restore equality.
The reporter independently reconstructs this comparison from the raw XML. Any new
instability must be measured and justified before extending this exception.
