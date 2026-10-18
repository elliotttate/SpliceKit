# Contributing v4 capabilities (draft)

Every new capability contribution must include offline tests, a reproducible live
plan, and evidence. These are proposed v4 contribution requirements; upstream release
policy and the v4 version name remain the maintainer's decision.

1. Add FCP-free tests under `tests/` for parameters/units, result envelope, unsupported
   state, identity/revision failures, and observable behavior. Test rollback damage and
   uncertain outcomes where relevant. Run `make` and `make test`; CI does the same on
   macOS without installing or launching Final Cut Pro. Optional OTIO setup is in
   [tests/README.md](tests/README.md).
2. Add `tests/live/v4/<domain>.json` using the
   [versioned live plan contract](tests/live/v4/SCHEMA.md). Bind the exact disposable
   library/project and rational frame rate. Each mutation needs independent native
   readback, an operation-owned undo, and comparison with the complete semantic
   baseline. Include 30 and 30000/1001 frame boundaries where timing is affected.
   Native analysis that is only admitted/rejected must use `kind: admission`, explicitly
   prove `native_started=false`/`ready=false`, and retain its unimplemented status.
3. Run the plan only in an authorized live session, with exactly one `SpliceKit-Test*`
   library open. Use the generated original
   [fixtures](tests/live/fixtures/README.md). Preserve before/after/undo state, result
   envelopes, runtime FCP build/macOS/architecture, and raw RPC transcript under
   `evidence/YYYY-MM-DD/`. Never retry an uncertain mutation or issue a generic undo.
4. Include the evidence and generated promotion candidate with the review. Generate
   `docs/v4/SUPPORT_MATRIX.md` with `python3 -m tests.live.report`. Review canonical
   evidence/plan hashes and scope before merging a registry level change. A mock run
   stays `offline_tested`; an absent live run must remain explicitly pending. The
   presence of a JSON plan or method registration never proves native support.

Code and documentation are English. Keep existing v3 RPC/MCP behavior compatible;
new native domains use separate `SpliceKitV4*.m`/`.h` files and new `v4.<domain>.*`
methods. Keep changes reviewable and split build fixes from new domain behavior.
Do not deploy a test build, write into an installed FCP application, or contact an
upstream maintainer as part of the test command.

There are four independent acceptance gates: static/plan validation, independent host
readback, perceptual review, and native persistence/restore. Record `not_checked` for
unperformed checks. This runner verifies host state and owned undo on the named fixture;
it does not listen, judge aesthetics, or test save/reopen durability. Those require
separate native artifacts and review, scoped to the same revision/build. `live_verified`
is build/fixture/domain evidence, not blanket production enablement.

The live runner deliberately requires the fixture project to be open before execution.
Do not loosen library/path guards to make a test pass. If a native API, owned undo, or
independent readback is unavailable, report it as pending/unsupported and add a blocked
admission test where useful. Preserve failed/unknown evidence and reconcile the operation
identity and host baseline before explicitly clearing its quarantine latch.
