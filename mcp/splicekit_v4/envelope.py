"""Shared v4 result envelope, with no transport or MCP dependency.

Use ``result(operation_id=..., applied=..., readback=...)`` for success and
``failure(code, message, operation_id=..., applied=...)`` for errors. ``applied``
is None when execution may be partial or is still pending; never turn a timeout
into applied=False. ``pending`` means accepted, not completed. The optional
``status`` extension belongs to the operation core; all ten base keys are always
present, including ``error=None`` on success. ObjC: Sources/SpliceKitV4Result.h.
Evidence describes validation of the capability, not visual/audio acceptance.
"""
from __future__ import annotations

from copy import deepcopy
from typing import Any

EVIDENCE_LEVELS = ("static", "offline_tested", "live_verified")
UNDO_KINDS = ("native_group", "none", "unknown")
RESULT_SCHEMA: dict[str, Any] = {
    "$schema": "https://json-schema.org/draft/2020-12/schema",
    "type": "object",
    "required": ["ok", "operation_id", "applied", "readback", "revision_before",
                 "revision_after", "undo", "evidence_level", "warnings", "error"],
    "properties": {
        "ok": {"type": "boolean"},
        "operation_id": {"type": "string"},
        "applied": {"type": ["boolean", "null"]},
        "readback": {"type": ["object", "null"]},
        "revision_before": {"type": ["string", "null"]},
        "revision_after": {"type": ["string", "null"]},
        "undo": {"type": "object", "required": ["kind", "label"], "properties": {
            "kind": {"enum": list(UNDO_KINDS)}, "label": {"type": "string"}}},
        "evidence_level": {"enum": list(EVIDENCE_LEVELS)},
        "warnings": {"type": "array"},
        "error": {"oneOf": [{"type": "null"}, {"type": "object",
            "required": ["code", "message", "retryable"], "properties": {
                "code": {"type": "string"}, "message": {"type": "string"},
                "retryable": {"type": "boolean"}}}]},
        "status": {"type": "string"},
    },
    "allOf": [{"if": {"properties": {"ok": {"const": True}}},
               "then": {"properties": {"error": {"type": "null"}}},
               "else": {"properties": {"error": {"type": "object"}}}}],
}


def validate_envelope(value: dict[str, Any]) -> dict[str, Any]:
    """Validate the base contract without requiring a JSON Schema dependency."""
    if not isinstance(value, dict):
        raise ValueError("envelope must be an object")
    missing = set(RESULT_SCHEMA["required"]) - value.keys()
    if missing:
        raise ValueError(f"missing fields: {', '.join(sorted(missing))}")
    if type(value["ok"]) is not bool or not isinstance(value["operation_id"], str):
        raise ValueError("ok must be boolean and operation_id must be string")
    if value["applied"] is not None and type(value["applied"]) is not bool:
        raise ValueError("applied must be boolean or null")
    if value["readback"] is not None and not isinstance(value["readback"], dict):
        raise ValueError("readback must be object or null")
    for key in ("revision_before", "revision_after"):
        if value[key] is not None and not isinstance(value[key], str):
            raise ValueError(f"{key} must be string or null")
    undo = value["undo"]
    if (not isinstance(undo, dict) or undo.get("kind") not in UNDO_KINDS
            or not isinstance(undo.get("label"), str)):
        raise ValueError("undo requires kind and label")
    if value["evidence_level"] not in EVIDENCE_LEVELS or not isinstance(value["warnings"], list):
        raise ValueError("invalid evidence_level or warnings")
    error = value["error"]
    if error is not None and (not isinstance(error, dict)
            or not isinstance(error.get("code"), str)
            or not isinstance(error.get("message"), str)
            or type(error.get("retryable")) is not bool):
        raise ValueError("error requires code, message and retryable")
    if value["ok"] != (error is None):
        raise ValueError("ok must agree with error")
    if "status" in value and not isinstance(value["status"], str):
        raise ValueError("status must be string")
    return value


def result(*, operation_id: str = "", ok: bool = True, applied: bool | None = False,
           readback: dict[str, Any] | None = None, revision_before: str | None = None,
           revision_after: str | None = None, undo_kind: str = "none", undo_label: str = "",
           evidence_level: str = "offline_tested", warnings: list[Any] | None = None,
           error: dict[str, Any] | None = None, status: str | None = None) -> dict[str, Any]:
    """Build a complete envelope; nested caller data is copied, never aliased."""
    value = {"ok": ok, "operation_id": operation_id, "applied": applied,
             "readback": deepcopy(readback), "revision_before": revision_before,
             "revision_after": revision_after, "undo": {"kind": undo_kind, "label": undo_label},
             "evidence_level": evidence_level, "warnings": deepcopy([] if warnings is None else warnings),
             "error": deepcopy(error)}
    if status is not None:
        value["status"] = status
    return validate_envelope(value)


def failure(code: str, message: str, *, operation_id: str = "", applied: bool | None = None,
            readback: dict[str, Any] | None = None, retryable: bool = False,
            **kwargs: Any) -> dict[str, Any]:
    """An ambiguous error is not retryable; poll/reconcile the same operation ID."""
    return result(operation_id=operation_id, ok=False, applied=applied, readback=readback,
                  undo_kind=kwargs.pop("undo_kind", "unknown" if applied is None else "none"),
                  error={"code": code, "message": message, "retryable": retryable}, **kwargs)


def pending(operation_id: str, *, state: str = "QUEUED") -> dict[str, Any]:
    return result(operation_id=operation_id, applied=None, readback={"state": state},
                  undo_kind="unknown", status="pending")


# Explicit aliases for callers that prefer constructor-style names.
make_result = result
error_result = failure
