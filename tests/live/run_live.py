#!/usr/bin/env python3
"""Verify v4 operations on exactly one disposable library; never launch FCP."""
import argparse
from contextlib import contextmanager
from datetime import datetime, timezone
import fcntl
from fractions import Fraction
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import uuid

if __package__ in (None, ""):
    sys.path.insert(0, str(Path(__file__).resolve().parents[2]))

from tests.live.contract import (VerificationError, assertions, digest, pointer, projection,
                                 resolve, validate_envelope, validate_plan)
from tests.live.rpc import RPCClient, RPCError, UnknownOutcome

ROOT = Path(__file__).resolve().parents[2]


def write_json(path, value, replace=False):
    """Atomically publish without replacing prior evidence."""
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, name = tempfile.mkstemp(prefix=".evidence-", dir=path.parent)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as stream:
            json.dump(value, stream, indent=2, sort_keys=True, allow_nan=False)
            stream.write("\n")
            stream.flush()
            os.fsync(stream.fileno())
        if replace:
            os.replace(name, path)
            name = None
        else:
            os.link(name, path)
    finally:
        if name:
            os.unlink(name)


@contextmanager
def writer_lock(port):
    # Endpoint-wide lock shared by worktrees, not a per-plan lock.
    path = Path(tempfile.gettempdir()) / f"splicekit-v4-live-{port}.lock"
    with path.open("a", encoding="utf-8") as stream:
        try:
            fcntl.flock(stream, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError as exc:
            raise VerificationError("Another live runner owns this bridge") from exc
        try:
            yield
        finally:
            fcntl.flock(stream, fcntl.LOCK_UN)


def libraries(rpc):
    """Use upstream selectors also exercised by fcp-ai's FCP 12.4 library probe."""
    handles = []

    def invoke(target, selector, args=None, **options):
        value = rpc.call("system.callMethodWithArgs", {
            "target": target, "selector": selector, "args": args or [], **options})
        if options.get("returnHandle"):
            if not isinstance(value, dict) or not isinstance(value.get("handle"), str):
                raise VerificationError("Library identity probe did not return a handle")
            handles.append(value["handle"])
            return value["handle"]
        if not isinstance(value, dict) or "result" not in value:
            raise VerificationError("Library identity probe did not return a scalar")
        return value["result"]

    try:
        array = invoke("FFLibraryDocument", "copyActiveLibraries", classMethod=True, returnHandle=True)
        count = invoke(array, "count")
        if type(count) is not int or count < 0:
            raise VerificationError("Invalid active library count")
        if count != 1:
            raise VerificationError(f"Exactly one open library required; found {count}")
        library = invoke(array, "objectAtIndex:", [{"type": "int", "value": 0}], returnHandle=True)
        name = invoke(library, "displayName")
        url = invoke(library, "URL", returnHandle=True)
        path = invoke(url, "path")
        return [{"name": name, "path": path}]
    finally:
        for handle in reversed(handles):
            # Release only this probe's handles, never all bridge handles.
            rpc.call("object.release", {"handle": handle})


def guard(rpc, fixture, library_path, check_project=True):
    library = libraries(rpc)[0]
    name, path = library["name"], library["path"]
    if (not isinstance(name, str) or not name.startswith("SpliceKit-Test") or
            name != fixture["library_name"] or not isinstance(path, str) or
            Path(path).resolve() != Path(library_path).resolve() or
            not Path(path).name.startswith("SpliceKit-Test")):
        raise VerificationError("Library name/path differs from the explicit disposable fixture")
    if check_project:
        state = rpc.call("timeline.getDetailedState", {"limit": 1})
        if not isinstance(state, dict) or state.get("sequenceName") != fixture["project"]:
            raise VerificationError("The exact fixture project must already be open")
        frame = state.get("frameDuration", {})
        if (type(frame.get("value")) is not int or type(frame.get("timescale")) is not int or
                frame["timescale"] <= 0 or
                Fraction(frame["value"], frame["timescale"]) != Fraction(fixture["frame_duration"][:-1])):
            raise VerificationError("Fixture frame duration differs from the plan's exact rational rate")
    return library


def runtime_metadata(rpc, mode):
    runtime = rpc.call("system.version")
    if not isinstance(runtime, dict):
        raise VerificationError("Missing host version metadata")
    if mode == "live":
        for field in ("fcp_build", "fcp_version", "splicekit_version", "macos_version", "arch"):
            if not isinstance(runtime.get(field), str) or runtime[field].lower() in {"", "unknown"}:
                raise VerificationError("Missing runtime identity: " + field)
        if runtime.get("simulated") or str(runtime["fcp_build"]).lower().startswith("mock"):
            raise VerificationError("A simulated host cannot produce live evidence")
    return runtime


def source_identity():
    def git(*args):
        result = subprocess.run(["git", *args], cwd=ROOT, text=True, capture_output=True, check=False)
        return result.stdout.strip() if result.returncode == 0 else None
    return {"commit": git("rev-parse", "HEAD"), "dirty": bool(git("status", "--porcelain"))}


def run_plan(plan, rpc, library_path, mode="live"):
    """Return raw proof and gates. Never promote mocks or an incomplete cycle."""
    validate_plan(plan)
    if plan.get("template", False) and mode != "mock":
        raise VerificationError("Template plans are mock-only; adapt and remove template before live use")
    proof = {
        "schema": "splicekit.live-evidence/1", "plan_id": plan["id"], "plan": plan,
        "plan_sha256": digest(plan), "run_id": str(uuid.uuid4()),
        "timestamp": datetime.now(timezone.utc).isoformat(), "mode": mode,
        "runner": source_identity(), "status": "failed", "evidence_level": "offline_tested",
        "fixture": {**plan["fixture"], "library_path": str(Path(library_path).resolve())},
        "gates": {"static": "passed", "host_readback": "not_checked",
                  "perceptual": "not_checked", "native_undo_restore": "not_checked",
                  "save_reopen": "not_checked", "user_acceptance": "not_checked"},
        "steps": [],
    }
    start = len(rpc.transcript)
    context = {"fixture": proof["fixture"]}
    try:
        proof["runtime"] = runtime_metadata(rpc, mode)
        proof["library"] = guard(rpc, plan["fixture"], library_path)
        for step in plan["steps"]:
            context = {"fixture": proof["fixture"], "run": {
                "operation_id": str(uuid.uuid4()), "check_operation_id": str(uuid.uuid4())}}
            kind = step.get("kind", "mutation")
            entry = {"id": step["id"], "capability": step["capability"], "kind": kind,
                     "evidence_level": "offline_tested", "status": "failed"}
            proof["steps"].append(entry)
            guard(rpc, plan["fixture"], library_path)
            read = step["readback"]
            read_params = resolve(read.get("params", {}), context)
            entry["baseline"] = rpc.call(read["method"], read_params)
            baseline = projection(entry["baseline"], read["compare"])
            revision_path = read.get("revision", "/revision")
            baseline_revision = pointer(entry["baseline"], revision_path)
            if not isinstance(baseline_revision, str) or not baseline_revision:
                raise VerificationError("Independent baseline needs a nonempty revision")
            # An unstable observer cannot prove restoration. Detect it before
            # dispatching any operation, retaining both complete raw responses.
            guard(rpc, plan["fixture"], library_path)
            entry["baseline_confirmation"] = rpc.call(read["method"], read_params)
            entry["baseline_sha256"] = digest(baseline)
            entry["baseline_confirmation_sha256"] = digest(
                projection(entry["baseline_confirmation"], read["compare"]))
            if (entry["baseline_sha256"] != entry["baseline_confirmation_sha256"] or
                    pointer(entry["baseline_confirmation"], revision_path) != baseline_revision):
                raise VerificationError("Independent baseline is unstable before apply; no operation was sent")
            # Resolve expected/baseline fields before dispatch, so malformed plans cannot write.
            expected = resolve(read["expect"], {**context, "baseline": entry["baseline"]})
            context["baseline"] = entry["baseline"]
            guard(rpc, plan["fixture"], library_path)
            apply_params = resolve(step["apply"].get("params", {}), context)
            if kind != "read":
                apply_params.setdefault("operation_id", context["run"]["operation_id"])
            context["apply_request"] = {"method": step["apply"]["method"], "params": apply_params}
            entry["apply_request"] = context["apply_request"]
            entry["run"] = context["run"]
            entry["apply"] = rpc.call(step["apply"]["method"], apply_params)
            applied = validate_envelope(entry["apply"])
            context["apply"] = applied
            if kind in {"admission", "read", "rejection"}:
                assertions(applied, resolve(step["apply"]["expect"], context))
                if applied["applied"] is not False or applied["undo"]["kind"] != "none":
                    raise UnknownOutcome("Blocked admission unexpectedly declared a mutation or undo group")
                guard(rpc, plan["fixture"], library_path)
                entry["after"] = rpc.call(read["method"], read_params)
                assertions(entry["after"], expected)
                if digest(projection(entry["after"], read["compare"])) != digest(baseline):
                    raise UnknownOutcome("Blocked admission changed independent host state")
                if pointer(entry["after"], revision_path) != baseline_revision:
                    raise UnknownOutcome("Blocked admission changed the host revision")
                entry["baseline_sha256"] = digest(baseline)
                entry["restored_sha256"] = digest(baseline)
                entry["undo"] = None
                entry["restored"] = entry["after"]
                self_checks(rpc, plan, library_path, step, entry, context)
                entry["status"] = "passed"
                continue
            if applied["applied"] is None or applied["undo"]["kind"] == "unknown":
                raise UnknownOutcome("Host reported an unsettled operation")
            if applied["applied"] is not True:
                raise VerificationError("Apply was rejected or did not apply a mutation")
            apply_failure = (VerificationError("Settled apply reported a domain verification failure")
                             if not applied["ok"] or applied["error"] is not None else None)
            if applied["undo"]["kind"] != "native_group":
                raise VerificationError("An owned native undo group is required")
            if not applied["revision_before"] or not applied["revision_after"]:
                raise VerificationError("Live writes require before/after revisions")
            if applied["revision_before"] != baseline_revision:
                raise UnknownOutcome("Apply's baseline revision does not match the independent read")
            context["apply"] = applied
            # Never treat the embedded envelope readback as independent host evidence.
            guard(rpc, plan["fixture"], library_path)
            entry["after"] = rpc.call(read["method"], read_params)
            if pointer(entry["after"], revision_path) != applied["revision_after"]:
                raise UnknownOutcome("Post-apply revision changed before independent readback")
            context["after"] = entry["after"]
            failure = apply_failure
            try:
                if apply_failure:
                    raise apply_failure
                if step["apply"].get("expect"):
                    assertions(applied, resolve(step["apply"]["expect"], context))
                self_checks(rpc, plan, library_path, step, entry, context)
                assertions(entry["after"], expected)
                if digest(projection(entry["after"], read["compare"])) == digest(baseline):
                    raise VerificationError("Mutation produced no independently observed state change")
            except VerificationError as exc:
                failure = exc
            # Once a settled apply and fresh readback exist, attempt only this operation's undo.
            guard(rpc, plan["fixture"], library_path)
            undo_params = resolve(step["undo"].get("params", {}), context)
            entry["undo"] = rpc.call(step["undo"]["method"], undo_params)
            undone = validate_envelope(entry["undo"])
            if undone["applied"] is None:
                raise UnknownOutcome("Host did not settle undo")
            if not undone["ok"] or undone["applied"] is not True or undone["error"] is not None:
                raise VerificationError("Owned undo did not succeed")
            if undone["revision_before"] != applied["revision_after"]:
                raise UnknownOutcome("Undo's source revision does not belong to this apply")
            guard(rpc, plan["fixture"], library_path)
            entry["restored"] = rpc.call(read["method"], read_params)
            if pointer(entry["restored"], revision_path) != undone["revision_after"]:
                raise UnknownOutcome("Post-undo revision differs from the independent readback")
            restored = projection(entry["restored"], read["compare"])
            entry["baseline_sha256"] = digest(baseline)
            entry["restored_sha256"] = digest(restored)
            if entry["baseline_sha256"] != entry["restored_sha256"]:
                raise VerificationError("Undo did not restore the complete declared baseline projection")
            if failure:
                raise failure
            entry["status"] = "passed"
            entry["evidence_level"] = "live_verified" if mode == "live" else "offline_tested"
        proof["status"] = "passed"
        has_mutations = any(s.get("kind", "mutation") == "mutation" for s in plan["steps"])
        proof["evidence_level"] = "live_verified" if mode == "live" and has_mutations else "offline_tested"
        gate = "passed" if mode == "live" else "simulated"
        proof["gates"]["host_readback"] = gate
        proof["gates"]["native_undo_restore"] = gate if has_mutations else "not_checked"
    except (VerificationError, RPCError, KeyError, TypeError, ValueError) as exc:
        proof["status"] = "unknown" if isinstance(exc, UnknownOutcome) else "failed"
        proof["error"] = {"type": type(exc).__name__, "message": str(exc)}
    finally:
        proof["rpc_transcript"] = rpc.transcript[start:]
    return proof


def self_checks(rpc, plan, library_path, step, entry, context):
    """Record explicit ledger/replay/domain assertions inside a settled cycle."""
    entry["checks"] = []
    for check in step.get("after_apply", []):
        guard(rpc, plan["fixture"], library_path)
        arguments = resolve(check.get("params", {}), context)
        response = rpc.call(check["method"], arguments)
        entry["checks"].append({"method": check["method"], "params": arguments, "result": response})
        validate_envelope(response)
        assertions(response, resolve(check["expect"], context))


def promotion(proof, evidence_path):
    if (proof["mode"] != "live" or proof["status"] != "passed" or
            proof["evidence_level"] != "live_verified"):
        return None
    from tests.live.report import evidence_level
    if evidence_level(proof) != "live_verified":
        return None
    return {
        "schema": "splicekit.capability-evidence/1", "evidence": str(evidence_path),
        "evidence_sha256": digest(proof), "plan_sha256": proof["plan_sha256"],
        "fcp_build": proof["runtime"]["fcp_build"], "runtime": proof["runtime"],
        "timestamp": proof["timestamp"], "fixture": proof["fixture"],
        "scope": ["host_readback", "native_undo_restore"],
        "capabilities": [{"name": name, "evidence_level": "live_verified"}
                         for name in sorted({s["capability"] for s in proof["steps"]
                                             if s.get("kind", "mutation") == "mutation"})],
        "blocked_admissions": sorted({s["capability"] for s in proof["steps"] if s.get("kind") == "admission"}),
    }


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    mode = parser.add_mutually_exclusive_group(required=True)
    mode.add_argument("--live", action="store_true", help="Use an already-running isolated FCP")
    mode.add_argument("--mock", action="store_true", help="Offline proof only; never promotes capabilities")
    mode.add_argument("--check-plans", action="store_true", help="Validate plans without connecting")
    parser.add_argument("plans", nargs="*", type=Path)
    parser.add_argument("--library-path", type=Path)
    parser.add_argument("--port", type=int, default=9876)
    parser.add_argument("--timeout", type=float, default=10)
    parser.add_argument("--evidence-dir", type=Path, default=ROOT / "evidence")
    args = parser.parse_args(argv)
    suite = json.loads((ROOT / "tests/live/v4-suite.json").read_text())
    paths = args.plans or ([*sorted((ROOT / "tests/live/v4").glob("*.json"))] if args.check_plans
                          else [ROOT / "tests/live/v4" / name for name in suite["plans"]])
    try:
        if not paths:
            raise VerificationError("No live plans found")
        plans = [validate_plan(json.loads(path.read_text(encoding="utf-8"))) for path in paths]
        if len({p["id"] for p in plans}) != len(plans):
            raise VerificationError("Duplicate plan ids")
        if args.check_plans:
            print(f"Validated {len(plans)} live plans; no connection made")
            return 0
        if not args.library_path or not args.library_path.is_absolute():
            raise VerificationError("An absolute --library-path is required")
        if args.mock and args.port == 9876:
            raise VerificationError("Mock mode refuses the production bridge port 9876")
        if args.timeout <= 0 or not 1 <= args.port <= 65535:
            raise VerificationError("Invalid timeout or port")
        selected_mode = "mock" if args.mock else "live"
        quarantine = args.evidence_dir / f".quarantine-{args.port}.json"
        with writer_lock(args.port):
            if quarantine.exists():
                raise VerificationError(f"Previous unsettled/failed cycle requires manual reconciliation: {quarantine}")
            for plan in plans:
                # Validate the template fence before even querying a live endpoint.
                if plan.get("template", False) and selected_mode == "live":
                    raise VerificationError("Template plans are mock-only; adapt them before live use")
                rpc = RPCClient(port=args.port, timeout=args.timeout)
                write_json(quarantine, {"status": "in_progress", "plan_id": plan["id"],
                                        "plan_sha256": digest(plan)})
                proof = run_plan(plan, rpc, args.library_path, selected_mode)
                folder = args.evidence_dir / proof["timestamp"][:10]
                path = folder / (plan["id"] + ".json")
                if path.exists():
                    path = folder / (plan["id"] + "-" + proof["run_id"] + ".json")
                write_json(path, proof)
                candidate = promotion(proof, path)
                if candidate:
                    write_json(path.with_suffix(".promotion.json"), candidate)
                print(f"{plan['id']}: {proof['status']} ({proof['evidence_level']}) -> {path}")
                if proof["status"] != "passed":
                    # Keep the failed fixture from becoming a later test's baseline.
                    write_json(quarantine, {"evidence": str(path), "status": proof["status"],
                                            "error": proof.get("error")}, replace=True)
                    return 1
                quarantine.unlink()
        return 0
    except (VerificationError, RPCError, OSError, ValueError) as exc:
        print(str(exc), file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
