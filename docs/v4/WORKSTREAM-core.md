# Core workstream

This is the historical workstream report. [Integration README](README.md) and
[validation](VALIDATION.md) describe the final merged contract and current limits.

Branch: `v4/core`. This work adds the v4 operation boundary while preserving the
3.3.9 RPC path. The package version remains unchanged. No application was launched,
no installed application was modified, and no upstream push or PR was made.

## Implemented contract

- Every top-level v4 mutation reserves a durable `operation_id` before native
  execution. The same ID and arguments return the recorded result; different
  arguments produce `IDEMPOTENCY_CONFLICT`. Missing IDs are assigned UUIDs.
- A serial writer admits operations in reservation order and executes their
  complete synchronous native handlers on the main run loop. A client deadline
  does not release the writer. Reads bypass the writer; FCP-dependent reads still
  require main-thread time. `operation.status` is entirely ledger-only.
- After 20 seconds a mutation returns `ok:true`, `status:"pending"`,
  `applied:null`, and its ID. The native work continues exactly once and settles
  the ledger. Neither timeout nor UNKNOWN schedules a retry.
- JSONL reservations and updates are fsynced. On restart, queued/running entries
  become UNKNOWN. Historical settled results remain historical results, but their
  native undo ownership is never restored. A separate process lock prevents two
  hosts from owning the same bundle-scoped journal.
- Compaction retains the latest full record for **every** ID; it never evicts IDs
  that could then execute again. The log is bounded at 8 MiB and 10,000 IDs;
  record-size, capacity, corruption, lock and I/O failures close new writes. This
  intentionally requires an explicit future archival policy rather than silent
  loss of idempotency history. A torn final JSONL line can be repaired.
- `v4.operation.reconcile` observes fresh state and never reapplies anything. A
  generic revision alone cannot prove an edit. Optional `resolution`, nonempty
  `evidence`, and a matching fresh `expected_revision` explicitly attest an
  UNKNOWN result; the recorded warning identifies this as client evidence, not
  independent domain verification. Running operations cannot be attested away.
- `v4.state.revision` is a cheap **session-scoped concurrency token**: sequence
  and owning-document identity, observed undo epoch, top label, sequence name,
  and primary item count. It is not an XML/content hash. Native group-close,
  undo and redo notifications invalidate it conservatively, including human
  changes. A session UUID prevents tokens surviving a process restart.
- Mutation `expected_revision` is checked on main immediately before the handler.
  Independent reads receive before/after tokens; observed drift returns
  `OBSERVATION_CHANGED`. `operation.status` intentionally has no fresh native
  revision, because it must remain available while main is blocked.
- Undo is obtained from `sequence.modelDocument.undoHandler.undoManager` with no
  first-library fallback. Undoable handlers run in one named outer group and
  must register their own native inverses/transactions. The core does not invent
  rollback for direct setters. Missing native registration is reported as
  `undo.kind:"unknown"`. An unbalanced group fails explicitly.
- `v4.history.checkpoint` captures current state/history without modifying the
  native undo stack. `v4.history.undo` checks the same live owning manager,
  current session, unique top action label and unchanged post-operation revision.
  Otherwise it returns `UNDO_NOT_OWNED` or `UNDO_NOT_TOP`. Undo itself has an
  idempotent operation ID; human edits cannot be silently undone.
- v4 is routed before legacy dialog dismissal, legacy async dispatch and legacy
  error conversion. Nested legacy RPCs also skip dismissal inside the v4 scope.
  Modal sheets/windows yield `MODAL_PRESENT` with their title for domain reads
  and writes. Diagnostic `session.status` and ledger `operation.status` remain
  available without closing the modal.
- `v4.session.status` returns FCP version/build, SpliceKit version, SHA-256 of the
  loaded image's backing file, sequence/library information, modal state, revision
  mode, undo state, supported-build gate and ledger summary. The hash is cached at
  the first probe; an external replacement of that file afterward is not a proof
  of different already-mapped bytes. Supported build: `454072` (12.4).
  Unknown builds reject v4 writes with `UNSUPPORTED_BUILD` by default. An explicit
  operator startup override `SPLICEKIT_V4_BLOCK_UNSUPPORTED_BUILD=0` is visible in
  the probe; it is never enabled by an RPC or automatically.

## Integration API

See `Sources/SpliceKitV4Core.h`, `Sources/SpliceKitV4Result.h` and
`mcp/splicekit_v4/envelope.py`. Register full method names with the existing
plugin registry. Registry access now snapshots/locks handler metadata for
concurrent registration and dispatch.

Metadata keys:

- `readOnly`: true for reads; absent/false means a mutation.
- `v4Undo`: `native_group` (default) or explicit `none` for non-undoable media/UI
  work. An unknown value is rejected.
- `v4RequiresSequence`: true by default; false for library/session/file work.

Handlers receive all original parameters, plus a generated `operation_id` when
needed. A handler may return a complete shared envelope or a plain readback
object. Malformed envelopes and non-JSON results fail explicitly. The core stamps
its own operation ID, revisions and observed outer undo ownership.

Synchronous nested calls through `SpliceKit_handleRequest` are supported. Nested
v4 mutations inherit the outer ID, transaction and baseline revision; a different
ID or revision fails. Nested errors must propagate, with `applied:null` if prior
substeps may have applied. Reads cannot initiate nested v4 mutations. Every native
change must finish before the outer handler returns. Do not defer edits or pass
legacy `async:true`; use explicit domain job/status endpoints for asynchronous
media processing. Legacy calls initiated independently remain outside this v4
writer contract.

Canonical owned undo parameters:

```json
{"target_operation_id":"edit-id","operation_id":"undo-request-id","expected_revision":"fresh-token"}
```

Shorthand `{"operation_id":"edit-id"}` targets the edit and uses the deterministic
undo request ID `undo:edit-id`.

The envelope always includes `ok`, `operation_id`, `applied`, `readback`,
`revision_before`, `revision_after`, `undo`, `evidence_level`, `warnings`, and
`error`, including JSON null values. `status` is an optional core extension.
`error:null` stays inside the JSON-RPC result and never enters the legacy string
error adapter. Capability evidence remains `offline_tested`.

## Files and validation

- Native: `SpliceKitV4Core`, `SpliceKitV4OperationLedger`, `SpliceKitV4Result`
  headers/implementations; early v4 routing and registry locking in Server.
- Python: dependency-free envelope constructors, validation and shared JSON Schema.
- Discovery: `mcp/splicekit_v4/capabilities/core.json` contains all six RPCs.
- Native tests: `tests/v4_core_offline.m` links the actual ledger and scheduler to
  a fake host. It does not instantiate NSApplication or resolve FCP classes.
  Test journals stay below `build/v4-offline`; production journal initialization
  is bypassed by installing the test host before method registration.
- Python tests: `tests/test_v4_core.py` validates envelopes and native-exported
  envelope fixtures, compiles/runs the native tests, and checks early dispatch.
- Selector ABI evidence: `docs/v4/CORE-SELECTORS.md`.
- Live plan: `tests/live/v4/core.json` (not executed).

Reproduction:

```sh
python3 tests/test_v4_core.py
python3 -m unittest discover -s tests -p 'test_*.py'
make -j2
```

The full offline unittest discovery passes 80 tests with two optional-dependency
skips. It includes ten v4 Python tests and 199 native checks (many ledger checks
exercise compaction repeatedly). The universal build passes for arm64/x86_64.
Existing BRAW pointer-alignment linker warnings remain. A full `nm -u` check
finds no undefined internal SpliceKit symbols, including mangled C++ names. Live RPC/AI endpoint
scripts that require a running FCP are not run by this offline unittest suite.

A separate small build repair supplies four missing BRAW SDK-free entry points in
`SpliceKitV4BuildCompatibility.m`; it makes the existing build work without the
Blackmagic SDK. It does not enable BRAW decode and has no effect on SDK builds.
A second independent repair adds C linkage guards to `SpliceKit.h`: existing
ObjC++ callers otherwise referenced C++-mangled logger/main-thread symbols that
the dynamic-lookup linker left unresolved. `tests/test_cpp_api_linkage.py`
checks the actual compiler output for that ABI contract. The Makefile guard now
recognizes every internal SpliceKit name, including BRAW names and C++ mangling,
and reruns linking after Makefile changes. The independent preparation commits
are `f2ac68c`, `2a4d32e`, and `8df76c6`.

## UNVERIFIED runtime behavior

No private selector is unverified statically. These runtime integration boundaries
still need phase-two evidence and are marked `// UNVERIFIED:` in the core source:

1. FCP's FFUndoHandler transactions must nest correctly inside the single owning
   NSUndoManager group, including transitions, parameter actions and error paths.
   Ownership checks are conservative; they do not prove restoration of all native
   content or visual/audio equivalence.
2. FCP-native/manual edits must emit the observed undo notifications in time for
   the cheap token to invalidate. Unregistered raw setters are outside the token's
   coverage; domain-specific semantic/native readback remains mandatory.
3. Real FCP modal loops and busy/startup states must permit the run-loop probes;
   a busy main thread can delay native reads even while ledger status responds.

No deploy, import, playback, listening, visual acceptance or user approval is
claimed by offline results.

## Suggested upstream PR split

1. SDK-free BRAW link repair (already a separate commit).
2. Shared C/ObjC++ linkage repair with its regression test (separate commit).
3. Shared envelopes, durable operation boundary, v4 diagnostic/history RPCs,
   Server routing and native/Python offline tests.
4. Domain workstream registrations and their phase-two fixture evidence can be
   reviewed separately on top of this core. Keep package versioning for packaging.
