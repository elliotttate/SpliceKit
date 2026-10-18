# Proposed upstream PR sequence

Base: upstream `223694a` (3.3.9). Integrated implementation checkpoint:
`5aab936`. No PR, push, issue or comment has been sent. These are local review
units, not claims of maintainer approval. Keep Version.xcconfig unchanged.

The branch has six merged development histories, including redundant historical
BRAW compatibility files. **Do not cherry-pick every workstream commit wholesale.**
The first three bugfixes are independent. For later rows, the listed ranges are
exact source inventories; path-filter and squash the final integrated content on
top of the preceding PRs. Include only that PR's source-manifest entries and avoid
reintroducing already-landed fixes or the removed compatibility translation units.
`git diff <range> -- <paths>` makes each proposed change concrete for review.

## 1. SDK-free BRAW exports

- Source range: `223694a..d2ff1e6`, restricted to
  `Sources/SpliceKitBRAW.mm` and `tests/test_braw_optional_exports.py`.
- Draft title: **Define unconditional BRAW bridge exports in SDK-free builds**.
- Draft description: Clean builds without the proprietary SDK left four bridge
  entry points undefined. Define the no-op/unsupported implementations in the
  existing no-SDK branch and compile that branch in a regression test. SDK-enabled
  code is unchanged; no BRAW functionality or SDK dependency is introduced.
- Evidence: compiled export test PASS for all four C symbols; full universal build
  PASS and no unresolved internal SpliceKit symbols.
- Preparation: the final patch replaces historical `761e83f`, `784f19c`, `48a52a3`,
  `a4daeba`, `f2ac68c` and BRAW portions of `8df76c6`; those duplicate compatibility
  files must never appear in this PR. The four definitions live only in BRAW.mm.

## 2. Explicit false transition flag

- Commit range: `da3d012^..da3d012` (standalone cherry-pick).
- Draft title: **Preserve explicit false freeze-extend transition requests**.
- Draft description: The MCP wrapper dropped `freeze_extend=False`, letting the
  native default turn an explicit opt-out into freeze extension. Always transmit
  the boolean value and test both false and true transport.
- Evidence: `tests/test_transition_transport.py` PASS; existing behavior otherwise
  unchanged. Independent of v4 and PR 1.

## 3. Complete effect/transition identities

- Commit range: `15acd47^..15acd47` (standalone cherry-pick).
- Draft title: **Preserve complete effect and transition IDs in MCP output**.
- Draft description: Formatter slices truncated identifiers that clients need for
  exact native selection. Return the complete IDs and add output regressions;
  native catalog lookup and compatibility are unchanged.
- Evidence: `tests/test_effect_identity_output.py` PASS. Independent of v4 and PRs 1–2.

## 4. C/ObjC++ linkage and build guard

- Source ranges: `2a4d32e^..2a4d32e` plus `8df76c6^..8df76c6 -- Makefile`.
- Draft title: **Preserve C linkage and reject unresolved internal bridge symbols**.
- Draft description: ObjC++ clients referenced mangled versions of C runtime APIs
  that dynamic lookup left unresolved. Add linkage guards, compile an ABI regression,
  and make linking detect all internal SpliceKit names and Makefile changes.
- Evidence: `tests/test_cpp_api_linkage.py` PASS; universal build and final `nm -u`
  check PASS. Exclude the obsolete BRAW compatibility-file hunk from `8df76c6`.

## 5. Reproducible offline test infrastructure

- Source range: `223694a..5aab936`, restricted to `.github/workflows/v4-offline.yml`,
  the Makefile test target, `tests/{__init__,run,run_v4_offline,verify_otio_upstream}.py`,
  `tests/requirements-offline.txt`, `tests/README.md`, and the tests-workstream OTIO
  fixture assertion correction from `f024875`. Origins: `f024875`, `5aab936`.
- Draft title: **Run offline bridge tests locally and in macOS CI**.
- Draft description: Provide one offline entry point that excludes native/AI scripts,
  blocks FCP/external connections while allowing mock servers, and pins Python 3.12,
  OTIO and the fixture adapter. Install MCP and registry dependencies consistently.
  Keep the Python 3.14 OTIO dependency failure visible with an untouched-upstream
  reproduction command. Fixture assertions follow the pinned adapter's actual data.
- Evidence: final 171/171 PASS under CI-equivalent Python 3.12; supplied 3.14 has
  exactly two errors reproduced against untouched upstream. No new skips/xfails.
  The count is the final integrated suite; this early PR runs its available subset.

## 6. Durable native operation core

- Source range: `223694a..71f812c`, restricted to
  `Sources/SpliceKitV4{Core,OperationLedger,Result}.{h,m}`, core-only Server/SOURCES
  changes, `mcp/splicekit_v4/envelope.py`, `capabilities/core.json`, core selector
  documentation and `tests/{test_v4_core.py,v4_core_offline.m}`.
  Origins: `618e908`, `8398942`, `d2ff1e6`, `71f812c`.
- Draft title: **Add a durable v4 native operation boundary and owned undo**.
- Draft description: Route v4 before legacy side effects. Reserve operation identity
  durably, serialize native edits, check fresh revision preconditions on main, expose
  pending/status/reconcile without replay, and undo only the current owned top group.
  Add diagnostics, observational checkpoints and complete native XML snapshots.
  Document token/undo/restart limits; no restorable multi-step checkpoint is claimed.
- Evidence: 202 native core checks plus shared Python envelope tests PASS; current
  universal build PASS. Live transaction nesting and notification/XML stability
  remain required gates. Depends on PRs 4–5; no domain registration is needed here.

## 7. Typed parameters, exact effects and keyframes

- Source range: `223694a..71f812c`, restricted to V4 Parameters/Effects/Keyframes
  sources, params capability/contract/selector files, native params tests and the
  params manifest generator. Origins: `ee33c9d`, `d2ff1e6`, `71f812c`.
- Draft title: **Expose exact-instance effects and typed native parameter trees**.
- Draft description: Address clips by persistentID, effect instances by fileUUID and
  channels by numeric native paths. Support type-specific values, explicit rational
  time and scalar keyframes with native readback, key preservation and one core-owned
  transaction. Expose unknown units/time behavior explicitly.
- Evidence: 131 production-handler mock checks and all schema checks PASS; universal
  build PASS. Live curve coordinates/move semantics/units/undo remain unverified.
  Requires PR 6; independent bugfixes from PRs 1 and 3 are excluded from this diff.

## 8. Native titles, captions, transitions and generators

- Source range: `223694a..71f812c`, restricted to V4 TitlesSupport/TitleStyles/Titles/
  Captions/Transitions sources, titles descriptor/selector files and native tests.
  Origins: `4ac365f`, `d2ff1e6`, `71f812c`.
- Draft title: **Add identity-bound native text, captions and connected insertion**.
- Draft description: Edit explicit title fields/style spans and native caption blocks,
  use rational frame-aligned placement, and make transition handle policy explicit.
  Use the core's shared envelope/outer undo ownership and require synchronous native
  execution; do not allocate unused insertion handles.
- Evidence: 580 native mock assertions over 11 RPCs and descriptor validation PASS;
  universal build PASS. Optional persistence selectors and native transition output
  semantics remain live gates. Requires PR 6; params integration is used for discovery.

## 9. Audio, color, retime and honest analysis admission

- Source range: `223694a..71f812c`, restricted to V4 Media/Audio/Color/Retime/Analysis
  sources, media descriptor/selector files and native media tests.
  Origins: `557a650`, `d3724cc`, `d2ff1e6`, `71f812c`.
- Draft title: **Add typed native media edits with explicit analysis admission limits**.
- Draft description: Wrap discovered parameters and exact audio/retime operations in
  the native core transaction contract. Report blocked analysis admission/status/local
  cancellation without starting tasks or fabricating readiness/results. No calibrated
  custom curves, multicam or analysis execution is promised.
- Evidence: 72 native media checks PASS; all 18 descriptors match actual registrations;
  build PASS. Live stereo copying, audible component selection and time maps are open.
  Requires PRs 6–7.

## 10. Opt-in agent discovery and bounded editorial runtime

- Source range: `223694a..71f812c`, restricted to `mcp/server.py` mode/decorator changes,
  the remaining `mcp/splicekit_v4` registry/runtime/schema/plan/review files,
  `mcp/requirements.txt`, `tests/test_v4_agent.py`, and `examples/v4`.
  Origins: `84318be`, `9d37191`, `71f812c`.
- Draft title: **Add opt-in typed v4 discovery without changing the legacy toolset**.
- Draft description: Keep legacy as default; expose seven v4 bootstrap tools and load
  build/evidence-scoped schemas on demand. Validate exact native plan arguments and
  nested target scope, preserve pending/terminal native ledger semantics, and fence
  missing checkpoint/source/viewer contracts before writing. Include a synthetic
  provider-neutral/Gemini example without shipping fake native capabilities.
- Evidence: agent fault-injection/toolset tests, real descriptor loading, pending-to-
  terminal ledger test and two-round no-network dry-run PASS. Native full plan/review
  is explicitly unavailable. Requires PRs 6–9 for the complete production catalog.
  Remove PR 2/3 formatter/transport hunks already applied to server.py.

## 11. Integrated verification plans and beta documentation

- Commit ranges: `0814bdd^..0814bdd` plus the documentation commit adding this plan;
  supporting live/fixture origins are `0a8ac67` and `ed857ca` from `v4/tests`.
- Draft title: **Verify the integrated v4 registry and sequential owned-undo suite**.
- Draft description: Compile every production v4 registration and enforce a descriptor
  bijection. Validate all eight live plans; run 46 steps in one read/core/params/titles/
  media sequence. Preserve complete raw native XML and domain observations through
  owned undo, quarantine ambiguous outcomes, and keep all templates/perceptual gates
  explicit. Document the architecture, exact local/CI evidence and remaining gaps.
- Evidence: 49/49 compiled parity, eight valid plans, live-runner loopback fault tests,
  final 171/171 Python 3.12 suite, and universal build PASS. No live capability
  promotion or deployment. This is last because it binds every preceding API.

Before opening any PR, prepare its actual small branch/commit on the previous
accepted layer, rerun that layer's tests and review the concrete diff. Do not submit
the six-way merge history, private fixture identities, ignored logs/venvs, installed
application paths or a package-version bump. Native live evidence belongs to a later
explicitly authorized fixture run and must retain its exact build/binary/scope.
