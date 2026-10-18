#!/usr/bin/env python3
"""Plan -> apply -> native evidence -> critique -> revision-bound correction.

Default requires --dry-run or explicit --live. Dry-run makes no network calls and
never imports the MCP server (which would discover legacy plugins at startup).
"""

import argparse
import base64
import copy
import json
import mimetypes
import os
import re
import sys
import tempfile
import urllib.request
from pathlib import Path
from typing import Protocol

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "mcp"))

from splicekit_v4.contracts import ContractError
from splicekit_v4.registry import digest, load_schema, validate
from splicekit_v4.runtime import AgentRuntime


class VideoModel(Protocol):
    """Only this interface is provider-specific; other adapters can implement it."""

    def plan(self, brief: str, context: dict, media: Path) -> dict: ...

    def critique(self, brief: str, context: dict, artifact: dict) -> dict: ...


class GeminiVideoModel:
    def __init__(self, model):
        self.api_key = os.environ["GEMINI_API_KEY"]
        if not model or not re.fullmatch(r"[A-Za-z0-9._-]+", model):
            raise ValueError("Set GEMINI_MODEL to a supported video-capable Gemini model ID")
        self.model = model

    def generate(self, prompt, media):
        path = Path(media)
        if path.stat().st_size > 10 * 1024 * 1024:
            raise ValueError("This minimal example accepts inline media up to 10 MiB; use a Files API adapter for larger media")
        mime = mimetypes.guess_type(path.name)[0] or "application/octet-stream"
        if not mime.startswith(("video/", "image/")):
            raise ValueError("Expected video or image evidence")
        payload = {"contents": [{"role": "user", "parts": [
            {"text": prompt}, {"inline_data": {"mime_type": mime,
             "data": base64.b64encode(path.read_bytes()).decode()}}]}],
            "generationConfig": {"responseMimeType": "application/json"}}
        request = urllib.request.Request(
            "https://generativelanguage.googleapis.com/v1beta/models/" + self.model + ":generateContent",
            data=json.dumps(payload).encode(),
            headers={"Content-Type": "application/json", "x-goog-api-key": self.api_key}, method="POST")
        # No automatic retry: this is a separately authorized, potentially paid API call.
        with urllib.request.urlopen(request, timeout=60) as response:
            document = json.load(response)
        parts = document["candidates"][0]["content"]["parts"]
        text = "".join(part.get("text", "") for part in parts if not part.get("thought"))
        return json.loads(text)

    def plan(self, brief, context, media):
        return self.generate("Return only an EditPlan JSON object. Use only the supplied capability schemas and "
                             "native source/word IDs. Times are rational seconds; ranges are half-open. Brief: "
                             + brief + "\nContext: " + json.dumps(context), media)

    def critique(self, brief, context, artifact):
        return self.generate("Review the actual FCP evidence against the brief. Return JSON with issues "
                             "[{range,evidence_ref,severity,category,target_id,suggested_operation}], and "
                             "correction_plan (EditPlan or null). Tie corrections to the artifact revision. "
                             "Use only supplied capabilities. A still cannot verify audio or motion. Brief: "
                             + brief + "\nContext: " + json.dumps(context), artifact["path"])


class DryRunModel:
    def plan(self, brief, context, media):
        from offline_host import example_plan
        return example_plan()

    def critique(self, brief, context, artifact):
        from offline_host import example_plan
        patch = example_plan()
        patch["base_revision"] = artifact["revision"]
        patch["operations"] = [copy.deepcopy(patch["operations"][1])]
        patch["operations"][0]["args"]["value"] = 0.9
        return {"issues": [{"range": artifact["range"], "evidence_ref": artifact["binding_hash"],
                            "severity": "minor", "category": "fixture", "target_id": "clip-1",
                            "suggested_operation": "parameter.set"}], "correction_plan": patch}


def invoke(runtime, name, arguments):
    found = runtime.capability_search(name, limit=50)
    if not found["ok"]:
        raise RuntimeError(found)
    described = runtime.capability_describe(name)
    if not described["ok"]:
        raise RuntimeError(described)
    response = runtime.capability_invoke(name, arguments, described["readback"]["schema_hash"])
    if not response["ok"]:
        raise RuntimeError(json.dumps(response))
    return response


def context_pack(runtime):
    state = runtime.state_data()
    capabilities = []
    # Bounded categories keep the model's context small as the registry grows.
    for category in ("timeline", "parameter", "title", "effect", "transition"):
        found = runtime.capability_search(category, limit=10)
        if not found["ok"]:
            raise RuntimeError(found)
        for item in found["readback"]["matches"]:
            described = runtime.capability_describe(item["name"])
            if described["ok"]:
                capabilities.append(described["readback"])
    return {"state": state, "capabilities": capabilities, "edit_plan_schema": load_schema("edit_plan.schema.json")}


def validate_critique(critique, context, artifact):
    validate(load_schema("critique.schema.json"), critique)
    from splicekit_v4.timing import rational
    available = {cap["name"] for cap in context["capabilities"]}
    targets = set(context["state"]["target_ids"])
    for issue in critique["issues"]:
        if issue["suggested_operation"] not in available or issue["target_id"] not in targets:
            raise ContractError("UNSUPPORTED_CRITIQUE", "Critique must use available capabilities and native target IDs")
        if issue["evidence_ref"] != artifact["binding_hash"]:
            raise ContractError("STALE_ARTIFACT", "Issue must cite the exact reviewed evidence binding")
        start, end = (rational(issue["range"][key]) for key in ("start", "end"))
        if not rational(artifact["range"]["start"]) <= start < end <= rational(artifact["range"]["end"]):
            raise ContractError("UNSUPPORTED_CRITIQUE", "Issue range is outside the actual captured evidence")


def run_loop(runtime, model: VideoModel, brief, media, max_corrections=1):
    context = context_pack(runtime)
    plan = model.plan(brief, context, media)
    rounds = []
    for round_index in range(max_corrections + 1):
        validation = invoke(runtime, "plan.validate", {"plan": plan})
        preview = invoke(runtime, "plan.preview_diff", {"plan": plan})
        applied = invoke(runtime, "plan.apply", {"plan": plan, "idempotency_key": "example/" + digest(plan)})
        state = runtime.state_data()
        # Viewer-frame fallback captures the current rendered playhead only. Native
        # Share must implement the job contract before motion/audio can be reviewed.
        start = state["playhead"]
        from splicekit_v4.timing import json_time, rational
        capture_request = {"project_id": plan["project_id"], "sequence_id": plan["sequence_id"],
                           "expected_revision": applied["revision_after"], "mode": "viewer_frame",
                           "range": {"start": start, "end": json_time(rational(start) + 1)}, "max_dimension": 640}
        captured = invoke(runtime, "review.capture", {"request": capture_request})
        artifact = captured["readback"]["artifact"]
        path = Path(artifact["path"])
        import hashlib
        if hashlib.sha256(path.read_bytes()).hexdigest() != artifact["sha256"]:
            raise ContractError("STALE_ARTIFACT", "Artifact bytes changed before model review")
        if digest({key:value for key,value in artifact.items() if key != "binding_hash"}) != artifact["binding_hash"]:
            raise ContractError("STALE_ARTIFACT", "Artifact identity binding changed before model review")
        context = context_pack(runtime)
        if context["state"]["revision"] != artifact["revision"]:
            raise ContractError("STALE_ARTIFACT", "Timeline changed before critique")
        context["applied_diff"] = preview["readback"]["changes"]
        context["artifact"] = artifact
        critique = model.critique(brief, context, artifact)
        validate_critique(critique, context, artifact)
        rounds.append({"validation": validation["ok"], "apply": applied, "review": captured, "critique": critique})
        correction = critique.get("correction_plan")
        if not critique.get("issues") or correction is None or round_index == max_corrections:
            break
        if (correction.get("base_revision") != artifact["revision"]
                or correction.get("project_id") != artifact["project_id"]
                or correction.get("sequence_id") != artifact["sequence_id"]):
            raise ContractError("STALE_REVISION", "Correction must target the reviewed project/sequence/revision")
        plan = correction
    return {"rounds": rounds, "visual": "model_reviewed", "audio": "not_checked", "motion": "not_checked",
            "user_acceptance": "not_requested", "native_live_verified": False}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    mode = parser.add_mutually_exclusive_group(required=True)
    mode.add_argument("--dry-run", action="store_true")
    mode.add_argument("--live", action="store_true", help="Use an already-running isolated native test host and Gemini API")
    parser.add_argument("--brief", default="Keep the first two words; adjust clip opacity")
    parser.add_argument("--media", type=Path)
    parser.add_argument("--model", default=os.environ.get("GEMINI_MODEL"))
    parser.add_argument("--max-corrections", type=int, choices=range(0, 4), default=1)
    args = parser.parse_args()
    if args.dry_run:
        from offline_host import make_runtime
        with tempfile.TemporaryDirectory(prefix="splicekit-v4-dry-") as directory:
            runtime, host = make_runtime(directory)
            report = run_loop(runtime, DryRunModel(), args.brief, None, args.max_corrections)
            report.update(dry_run=True, synthetic_artifacts=True, network_calls=0, native_calls=0,
                          artifact_lifetime="temporary; removed at exit", final_revision=host.state["revision"],
                          visual="simulated_model_review")
            print(json.dumps(report, indent=2))
    else:
        if not args.media:
            parser.error("--live requires --media and GEMINI_API_KEY; host must already be running")
        # Import only the TCP client. No FCP launch, deployment or legacy discovery.
        from splicekit_v4.transport import TCPBridge
        runtime = AgentRuntime(TCPBridge())
        print(json.dumps(run_loop(runtime, GeminiVideoModel(args.model), args.brief, args.media,
                                  args.max_corrections), indent=2))


if __name__ == "__main__":
    main()
