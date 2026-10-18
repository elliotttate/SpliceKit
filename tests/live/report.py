#!/usr/bin/env python3
"""Generate a build-scoped Markdown support matrix from raw evidence and registries."""
import argparse
import json
from pathlib import Path
import sys

if __package__ in (None, ""):
    sys.path.insert(0, str(Path(__file__).resolve().parents[2]))

from tests.live.contract import (VerificationError, assertions, digest, pointer, projection,
                                 resolve, validate_envelope, validate_plan)

ROOT = Path(__file__).resolve().parents[2]


def evidence_level(proof):
    """Recheck raw cycles instead of trusting a file's advertised promotion level."""
    plan = validate_plan(proof["plan"])
    if proof["plan_sha256"] != digest(plan):
        raise VerificationError("Plan hash does not match evidence")
    if proof["status"] != "passed":
        return "not_verified"
    if len(proof["steps"]) != len(plan["steps"]):
        raise VerificationError("Incomplete step evidence")
    for step, spec in zip(proof["steps"], plan["steps"]):
        if step["id"] != spec["id"] or step["capability"] != spec["capability"] or step["status"] != "passed":
            raise VerificationError("Step identity/status mismatch")
        if proof["mode"] == "live" or "baseline_confirmation" in step:
            read = spec["readback"]
            before = digest(projection(step["baseline"], read["compare"]))
            confirmed = digest(projection(step["baseline_confirmation"], read["compare"]))
            revision = read.get("revision", "/revision")
            if (before != confirmed or before != step["baseline_sha256"] or
                    confirmed != step["baseline_confirmation_sha256"] or
                    pointer(step["baseline"], revision) != pointer(step["baseline_confirmation"], revision)):
                raise VerificationError("Unstable pre-apply baseline cannot prove restoration")
        validate_envelope(step["apply"])
        context = {"fixture": proof["fixture"], "baseline": step["baseline"],
                   "apply": step["apply"], "after": step["after"],
                   "apply_request": step.get("apply_request"), "run": step.get("run")}
        if len(step.get("checks", [])) != len(spec.get("after_apply", [])):
            raise VerificationError("Incomplete post-apply assertions")
        for check, observed in zip(spec.get("after_apply", []), step.get("checks", [])):
            if observed["method"] != check["method"] or observed["params"] != resolve(check.get("params", {}), context):
                raise VerificationError("Post-apply call identity mismatch")
            assertions(observed["result"], resolve(check["expect"], context))
        if spec.get("kind", "mutation") in {"admission", "read", "rejection"}:
            assertions(step["apply"], resolve(spec["apply"]["expect"], context))
            assertions(step["after"], resolve(spec["readback"]["expect"], context))
            if step["apply"]["applied"] is not False or step["apply"]["undo"]["kind"] != "none" or step["undo"] is not None:
                raise VerificationError("Blocked admission declared mutation/undo")
            before = digest(projection(step["baseline"], spec["readback"]["compare"]))
            if (before != digest(projection(step["after"], spec["readback"]["compare"])) or
                    before != step["baseline_sha256"] or before != step["restored_sha256"] or
                    pointer(step["baseline"], spec["readback"].get("revision", "/revision")) !=
                    pointer(step["after"], spec["readback"].get("revision", "/revision"))):
                raise VerificationError("Blocked admission changed host state/revision")
            continue
        validate_envelope(step["undo"])
        for envelope in (step["apply"], step["undo"]):
            if not envelope["ok"] or envelope["applied"] is not True or envelope["error"] is not None:
                raise VerificationError("An operation envelope does not declare settled success")
        if step["apply"]["undo"]["kind"] != "native_group":
            raise VerificationError("Missing owned native undo")
        read = spec["readback"]
        assertions(step["after"], resolve(read["expect"], {"fixture": proof["fixture"], "baseline": step["baseline"]}))
        revision = read.get("revision", "/revision")
        if (pointer(step["baseline"], revision) != step["apply"]["revision_before"] or
                pointer(step["after"], revision) != step["apply"]["revision_after"] or
                step["undo"]["revision_before"] != step["apply"]["revision_after"] or
                pointer(step["restored"], revision) != step["undo"]["revision_after"]):
            raise VerificationError("Operation/readback revision mismatch")
        before = digest(projection(step["baseline"], spec["readback"]["compare"]))
        restored = digest(projection(step["restored"], spec["readback"]["compare"]))
        if before != restored or before != step["baseline_sha256"] or restored != step["restored_sha256"]:
            raise VerificationError("Baseline restore hash mismatch")
        if before == digest(projection(step["after"], spec["readback"]["compare"])):
            raise VerificationError("No independently observed mutation")
    if proof["mode"] == "mock":
        return "offline_tested"
    if all(step.get("kind", "mutation") != "mutation" for step in plan["steps"]):
        return "offline_tested"
    for field in ("fcp_build", "fcp_version", "splicekit_version", "macos_version", "arch"):
        if not isinstance(proof["runtime"].get(field), str) or proof["runtime"][field].lower() in {"", "unknown"}:
            raise VerificationError("Missing live runtime identity: " + field)
    if (proof["mode"] != "live" or plan.get("template", False) or proof["runtime"].get("simulated") or
            proof["runtime"].get("fcp_build", "").lower().startswith("mock") or
            proof["gates"]["host_readback"] != "passed" or
            proof["gates"]["native_undo_restore"] != "passed"):
        raise VerificationError("Invalid live evidence provenance/gates")
    return "live_verified"


def cell(value):
    return str(value).replace("|", "\\|").replace("\n", " ")


def render(evidence_dir, registry_dir):
    rows = []
    documented = set()
    for path in sorted(Path(evidence_dir).glob("*/*.json")):
        proof = json.loads(path.read_text(encoding="utf-8"))
        if proof.get("schema") != "splicekit.live-evidence/1":
            continue
        level = evidence_level(proof)
        build = proof.get("runtime", {}).get("fcp_build", "unknown")
        for step in proof["plan"]["steps"]:
            name = step["capability"]
            documented.add(name)
            result = "blocked admission (no native analysis)" if step.get("kind") == "admission" and proof["status"] == "passed" else proof["status"]
            scoped_level = "offline_tested" if step.get("kind") == "admission" and proof["status"] == "passed" else level
            rows.append((name, build, scoped_level, proof["timestamp"][:10], result,
                         proof["gates"].get("perceptual", "not_checked"),
                         (proof.get("runner", {}).get("commit") or "unknown")[:12] +
                         (" (dirty)" if proof.get("runner", {}).get("dirty") else ""), path.name))
    for path in sorted(Path(registry_dir).glob("*.json")):
        document = json.loads(path.read_text(encoding="utf-8"))
        entries = document if isinstance(document, list) else document.get("capabilities", [document])
        for entry in entries:
            if entry.get("name") and entry["name"] not in documented:
                # A registry declaration alone is never fresh live proof.
                level = entry.get("evidence_level", "static")
                if level == "live_verified":
                    level = "not_verified (missing raw evidence)"
                rows.append((entry["name"], "not measured", level, "not measured", "not run", "not_checked", "not measured", path.name))
    lines = ["# v4 support matrix", "", "Generated by `python3 -m tests.live.report`.", "",
             "Evidence is scoped to the recorded FCP build and fixture. Mock runs prove only",
             "the runner contract. Readback/undo does not establish picture, audio, save/reopen,",
             "or user acceptance; those gates remain separate in the raw evidence.", "",
             "The runner commit is provenance, not an attestation that a dirty checkout matches",
             "the loaded framework. Consult LIVE_REPORT for deployed binary hashes and pending fixes.", "",
             "| Capability | FCP build | Evidence level | UTC date | Result | Perceptual gate | Runner commit | Evidence file |",
             "| --- | --- | --- | --- | --- | --- | --- | --- |"]
    lines.extend("| " + " | ".join(map(cell, row)) + " |" for row in sorted(set(rows)))
    if not rows:
        lines.extend(["", "No capability evidence has been collected in this checkout."])
    return "\n".join(lines) + "\n"


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--evidence-dir", type=Path, default=ROOT / "evidence")
    parser.add_argument("--registry-dir", type=Path, default=ROOT / "mcp/splicekit_v4/capabilities")
    parser.add_argument("--output", type=Path, default=ROOT / "docs/v4/SUPPORT_MATRIX.md")
    args = parser.parse_args(argv)
    try:
        content = render(args.evidence_dir, args.registry_dir)
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(content, encoding="utf-8")
        print(args.output)
        return 0
    except (OSError, ValueError, KeyError, TypeError, VerificationError) as exc:
        print("Invalid evidence: " + str(exc), file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
