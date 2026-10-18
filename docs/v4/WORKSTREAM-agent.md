# Agent workstream delivery

This is the historical workstream report. [Integration README](README.md) and
[validation](VALIDATION.md) describe the final merged contract and current limits.

Branch: `v4/agent`. Base: upstream `223694a` (SpliceKit 3.3.9).
Design inputs: supplied E report sections 3.5, 5, 6 and 7; D report section 7.
All changes belong to the isolated agent worktree. No application launch, deploy,
installed-application write, model API request, push, PR, issue or external message.

## Added behavior

- `mcp/splicekit_v4/`: JSON Schema-validated multi-file capability registry; local
  references only; duplicate/unsafe descriptor rejection; discover/describe/hash
  gates; exact build scope; `static → offline_tested → live_verified → production`.
- Seven MCP bootstrap tools: session status, capability search/describe/invoke,
  state read, operation status and history checkpoint. `SPLICEKIT_TOOLSET` selects
  `legacy` (default), `v4` or `all`. V4 performs no startup plugin RPC and exposes
  no legacy tools, resources or prompts. The existing 221 static tools remain in
  legacy/all. All 267 existing Python function bodies are behaviorally unchanged
  after normalizing decorator routing/docstrings.
- EditPlan JSON Schema covers ordered source/word-bound cuts, titles, effects,
  parameters and transitions. Pure validation/diff precede application. Exact
  rational timing supports NTSC rates, outward source-frame word snapping and
  explicit constant-rate source-to-timeline mapping. Reverse/freeze/retime curves
  require a native time map; they are not guessed.
- Plan execution preflights every step and restoration contract/build, checks
  fresh native identity/revision/rate/source/word/target evidence, checkpoints,
  chains operation identities/revisions, and requires each native result/readback.
  Native no-ops need readback and unchanged revision. A known failure restores the
  owned checkpoint and verifies baseline; UNKNOWN defers restoration and blocks
  further writes. Session duplicate keys do not replay; changed payloads conflict.
- Review capture uses the existing native normal viewer route, rejects largest
  player/full-window fallback, bounds size using Apple sips, and binds actual
  one-frame coverage, revision, file SHA-256 and sidecar metadata hash. Native
  Share is an explicit unsupported contract until a completed native export job
  and file/range/dimensions/audio checks exist. No ffmpeg or source reconstruction.
- `examples/v4/gemini_edit_loop.py`: provider-neutral VideoModel interface, Gemini
  REST adapter reading key/model from environment, separate planning/critique
  calls, evidence/capability/target-bound issues, bounded correction plans.
  `--dry-run` uses an isolated mock registry/host and marks every fixture artifact
  synthetic/non-native. No credentials, network, native RPC or model call required.
- One-page [agent guide](AGENT_GUIDE.md) and [architecture diagram](ARCHITECTURE.md),
  plus [registry/core contract](REGISTRY_CONTRACT.md) and
  [native review design](NATIVE_REVIEW.md). The production registry intentionally
  contains no fake native capabilities; absent workstream bindings fail closed.

## Files and integration ownership

`mcp/server.py` is changed only by this workstream. Its legacy declarations route
through mode-aware decorators; dynamic plugin discovery is skipped in v4.
New implementation lives entirely under `mcp/splicekit_v4`. The sole extra runtime
requirement is jsonschema (not imported by legacy mode). Example mock descriptors
live under `examples/v4/fixtures`, outside the installed capability directory.

Native core must supply registered `state.read`, `operation.status`,
`history.checkpoint`, `history.restore` descriptors (documented `core.`/`v4.`
logical-name prefixes are also accepted). Concrete RPC names come only from those
descriptors. Native write schemas explicitly accept expected revision, operation
ID and idempotency key. The native mutation boundary owns cross-client single
writer, durable records, restart reconciliation and final target/revision checks.
Python serialization and its session cache do not replace those guarantees.

### Separate SDK-free build fix

The first `make` failed with two existing undefined exports:
`_SpliceKit_bootstrapBRAWAtLaunchPhase`, `_SpliceKit_handleBRAWAVProbe`.
`SpliceKitBRAW.mm` defines them only when the proprietary SDK is present; its
SDK-free branch omits them. New `Sources/SpliceKitV4AgentBuildCompat.m` supplies a
no-provider bootstrap and delegates AV probe to the existing SDK-missing error
stub **only when the same SDK header is absent**. SDK-enabled implementations
remain unchanged. One line is added to `Sources/SOURCES.txt`. No
`Sources/SpliceKitServer.m` edit is needed. For upstream, this can be a separate
portability PR or folded into the existing SDK-free branch by its owner.

## Validation

- `make`: PASS, universal arm64 + x86_64 Mach-O dylib; existing BRAW linker alignment
  warnings remain. No deploy target or application was run.
- New v4 unit/fault-injection tests: **34/34 PASS**, Python 3.14.
- Default-dependency offline suite: **103 total, 101 PASS, 2 optional OTIO skips**.
  `python tests/run_v4_offline.py` explicitly disables TCP connects, including
  legacy import-time plugin discovery. Existing Core Image 5,000-frame soak passed
  in the final run; an earlier concurrent-build run hit its timing threshold.
- Real MCP SDK 1.30 registration smoke: exactly the seven bootstrap tools; no
  startup bridge socket. Legacy AST comparison: 267 function bodies, zero changes.
- `python examples/v4/gemini_edit_loop.py --dry-run`: two rounds, mock revision
  `r0 → r2 → r3`, no network/model/native calls, synthetic artifacts, audio/motion/
  persistence/user acceptance explicitly not established. Python compile and
  `git diff --check` pass.

Optional OTIO investigation is **not green** and is not hidden by the default
skips: the current core package alone does not supply an FCPXML adapter. PyPI
`otio-fcpx-xml-adapter==1.0.0` lacks the fixture features. The fixture README pins
adapter PR #7 commit `20d9fa54141149c09d976f3520a8c29d8e5ad124`; that commit's wheel
metadata fails because LICENSE is missing, so it was loaded through its manifest
without modifying third-party source. Both OTIO 0.17.0 and 0.18.1 on Python 3.12
still produce two fixture assertion failures (4 timelines vs 3; 30.0s vs 30.5s).
The exact same **two failures reproduce using untouched upstream `223694a`
server.py**. No OTIO helper, fixture assertion or test skip logic was altered.
Python 3.14's locally built OTIO 0.18.1 additionally raises `bad any cast` loading
its own manifest. These dependency/fixture issues are separate from v4 and remain
open; only the original optional-dependency skip applies in the default suite.

Local ignored evidence is under `build/`: `agent-make.log`,
`agent-validation-final.log`, `agent-v4-verified.log`, `agent-dry-verified.json`,
`agent-real-mcp-smoke.log`, `agent-legacy-body-check.log`,
`agent-all-tests-pinned.log`, `agent-all-tests-otio017.log`,
`agent-otio-baseline-proof.log`. Test environments and third-party source stay in
ignored local build/virtualenv directories and are not committed.

## UNVERIFIED and live acceptance

No new private FCP selector is introduced. The `UNVERIFIED` marker in `review.py`
identifies native Share's missing completed-export contract. Additional open gates:

1. Merged core/editing schema compatibility, exact build scope, native ownership,
   durable duplicate/UNKNOWN/restart reconciliation and owned checkpoint restore.
   This workstream's mocks verify contracts, not native implementation.
2. Normal-viewer identity/readiness with browser/dual windows, displayed-frame
   latency, permissions, color/proxy correctness and atomic capture against human
   changes. Before/after revision checks cannot prevent change-away/change-back.
   Native Share video/audio capture is deliberately unavailable.
3. Real Gemini request/response behavior, meaningful visual criticism, unsupported
   issue rejection, linked audio/retime/compound/NTSC native boundaries and baseline
   restoration on real FCP fixtures. No live model or FCP quality claim is made.

[tests/live/v4/agent.json](../../tests/live/v4/agent.json) specifies isolated host,
fixtures, steps, readback and owned undo checks. A single authorized operator must
run it after integration; do not infer live success from these offline results.

## Suggested upstream split

1. SDK-free BRAW missing-export fix (independent portability change).
2. Opt-in v4 package/bootstrap/registry/plans/review contract, preserving default
   legacy behavior, with offline tests and fake fixture isolation.
3. Example loop, agent/architecture/integration documentation and live test plan.

Primary provider reference used for the example:
[Gemini generateContent](https://ai.google.dev/api/generate-content) and
[official video input documentation](https://ai.google.dev/gemini-api/docs/generate-content/video-understanding).
No provider/model availability or price claim is embedded in the implementation.
