"""Small dependency-free validator for the documented live plan contract."""
import hashlib
import json
import re
import sys
import xml.etree.ElementTree as ET
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "mcp"))
from splicekit_v4.envelope import validate_envelope as validate_shared_envelope

SCHEMA = "splicekit.live-plan/1"


class VerificationError(RuntimeError):
    pass


def digest(value):
    return hashlib.sha256(json.dumps(value, sort_keys=True, separators=(",", ":"),
                                     allow_nan=False).encode()).hexdigest()


def pointer(value, path):
    if path == "":
        return value
    if not isinstance(path, str) or not path.startswith("/"):
        raise VerificationError("Expected an RFC 6901 JSON pointer")
    for token in path[1:].split("/"):
        token = token.replace("~1", "/").replace("~0", "~")
        try:
            value = value[int(token)] if isinstance(value, list) else value[token]
        except (KeyError, IndexError, TypeError, ValueError) as exc:
            raise VerificationError("Missing readback path: " + path) from exc
    return value


def resolve(value, context):
    if isinstance(value, dict):
        if set(value) == {"$ref"}:
            return pointer(context, value["$ref"])
        return {key: resolve(item, context) for key, item in value.items()}
    if isinstance(value, list):
        return [resolve(item, context) for item in value]
    return value


def assertions(result, expected):
    for path, value in expected.items():
        actual = pointer(result, path)
        if digest(actual) != digest(value):
            raise VerificationError(f"Readback mismatch at {path}: {actual!r} != {value!r}")


def projection(result, paths):
    observation = result.get("readback", {}) if isinstance(result, dict) else {}
    if observation.get("comparison") == "exact except security-scoped bookmark bytes":
        raw = observation["raw_fcpxml"]
        tree = ET.fromstring(raw)
        pattern = r"(<bookmark(?:\s[^>]*)?>)[A-Za-z0-9+/=\s]*(</bookmark\s*>)"
        if len(re.findall(pattern, raw)) != len(tree.findall(".//bookmark")):
            raise VerificationError("Unexpected bookmark encoding")
        semantic = re.sub(pattern, r"\1\2", raw)
        identities = [{"id": a.get("id"), "duration": a.get("duration"), "format": a.get("format"),
                       "sources": ([a.get("src")] if a.get("src") is not None else []) +
                                  [rep.get("src") for rep in a.findall("media-rep")]}
                      for a in tree.findall("resources/asset")]
        if observation["state"] != {"fcpxml": semantic, "asset_identity": identities}:
            raise VerificationError("Semantic observation does not match retained raw XML and asset identities")
    return {path: pointer(result, path) for path in paths}


def validate_plan(plan):
    def require(condition, message):
        if not condition:
            raise VerificationError(message)

    require(isinstance(plan, dict) and plan.get("schema") == SCHEMA, "Unsupported plan schema")
    require(isinstance(plan.get("id"), str) and
            re.fullmatch(r"[a-zA-Z0-9][a-zA-Z0-9_-]{0,79}", plan["id"]), "Unsafe plan id")
    require(type(plan.get("template", False)) is bool, "template must be boolean")
    fixture = plan.get("fixture", {})
    require(isinstance(fixture, dict), "fixture must be an object")
    require(isinstance(fixture.get("library_name"), str) and
            fixture["library_name"].startswith("SpliceKit-Test"), "Test library prefix required")
    require(isinstance(fixture.get("project"), str) and
            fixture["project"].startswith("SpliceKit-Test"), "Exact fixture project required")
    require(fixture.get("frame_duration") in {"1/30s", "1001/30000s"}, "Unsupported fixture rate")
    steps = plan.get("steps")
    require(isinstance(steps, list) and bool(steps), "At least one step is required")
    identifiers = set()
    for step in steps:
        require(isinstance(step, dict), "Each step must be an object")
        require(isinstance(step.get("id"), str) and step["id"] not in identifiers,
                "Step ids must be unique strings")
        identifiers.add(step["id"])
        require(isinstance(step.get("capability"), str) and bool(step["capability"]),
                "A registry capability name is required")
        kind = step.get("kind", "mutation")
        require(kind in {"mutation", "admission", "read", "rejection"}, "Unknown step kind")
        for key in (("apply", "readback", "undo") if kind == "mutation" else ("apply", "readback")):
            call = step.get(key)
            require(isinstance(call, dict) and isinstance(call.get("method"), str)
                    and bool(call["method"]) and isinstance(call.get("params", {}), dict),
                    key + " needs a method and object params")
        require(step["apply"]["method"].startswith("v4."), "Apply must use a v4 operation envelope")
        require(kind == "read" or step["readback"]["method"] != step["apply"]["method"], "Readback must be independent")
        if kind == "mutation":
            require(step["undo"]["method"].startswith("v4."), "Owned v4 undo is required")
            require(step["readback"]["method"] != step["undo"]["method"], "Readback must be independent")
            require(step["undo"].get("params", {}).get("operation_id") ==
                    {"$ref": "/apply/operation_id"}, "Undo must bind to the returned operation_id")
        else:
            require(step.get("undo") is None, "Read/rejection/admission checks must not issue undo")
            admission = step["apply"].get("expect", {})
            require(isinstance(admission, dict) and admission.get("/applied") is False,
                    "Nonmutation checks must explicitly expect applied=false")
            for flag in (("native_started", "ready") if kind == "admission" else ()):
                require(any(path.endswith("/" + flag) and value is False for path, value in admission.items()),
                        "Admission must explicitly expect " + flag + "=false")
        for check in step.get("after_apply", []):
            require(isinstance(check, dict) and isinstance(check.get("method"), str)
                    and check["method"].startswith("v4.") and isinstance(check.get("params", {}), dict)
                    and isinstance(check.get("expect"), dict) and bool(check["expect"]),
                    "after_apply checks require a v4 method, params and explicit expectations")
        expected = step["readback"].get("expect")
        require(isinstance(expected, dict) and bool(expected), "Nonempty readback expectations required")
        paths = step["readback"].get("compare")
        require(isinstance(paths, list) and bool(paths) and len(paths) == len(set(paths)),
                "Nonempty unique baseline comparison paths required")
        require(all(any(field == path or field.startswith(path + "/") for path in paths)
                    for field in expected), "Every asserted field must participate in undo comparison")
        require(isinstance(step["readback"].get("revision", "/revision"), str) and
                step["readback"].get("revision", "/revision").startswith("/"),
                "Readback revision must be an explicit JSON pointer")
        for path in [*expected, *paths]:
            require(isinstance(path, str) and path.startswith("/"), "Use explicit non-root JSON pointers")
    return plan


def validate_envelope(value):
    """Use core's dependency-free contract, with a live evidence identity gate."""
    try:
        validate_shared_envelope(value)
        if not value['operation_id']:
            raise ValueError('Live evidence requires a nonempty operation_id')
    except ValueError as exc:
        raise VerificationError(str(exc)) from exc
    return value
