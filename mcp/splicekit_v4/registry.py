"""Fail-closed capability discovery with local-only JSON Schema validation."""

import copy
import hashlib
import json
from pathlib import Path

from jsonschema import Draft202012Validator

from .contracts import ContractError

ROOT = Path(__file__).parent


def digest(value):
    return hashlib.sha256(json.dumps(value, sort_keys=True, separators=(",", ":"),
                                     allow_nan=False).encode()).hexdigest()


def load_schema(name):
    return json.loads((ROOT / "schemas" / name).read_text())


def check_schema(schema):
    """Never resolve a network/file reference supplied by a manifest."""
    def walk(node):
        if isinstance(node, dict):
            for key, value in node.items():
                if key in ("$ref", "$dynamicRef") and not value.startswith("#"):
                    raise ContractError("INVALID_SCHEMA", "Only document-local schema references are allowed")
                if key in ("$ref", "$dynamicRef") and value.startswith("#/"):
                    target = schema
                    try:
                        for part in value[2:].split("/"):
                            target = target[part.replace("~1", "/").replace("~0", "~")]
                    except (KeyError, TypeError) as exc:
                        raise ContractError("INVALID_SCHEMA", f"Unresolved local schema reference: {value}") from exc
                walk(value)
        elif isinstance(node, list):
            for value in node:
                walk(value)
    walk(schema)
    Draft202012Validator.check_schema(schema)


def validate(schema, instance):
    try:
        Draft202012Validator(schema, format_checker=Draft202012Validator.FORMAT_CHECKER).validate(instance)
        # Reject NaN/Infinity even when the schema permits an arbitrary value.
        json.dumps(instance, allow_nan=False)
    except (ValueError, TypeError) as exc:
        raise ContractError("SCHEMA_VALIDATION", str(exc)) from exc
    except Exception as exc:
        # ValidationError has a useful path; avoid leaking an enormous schema.
        path = ".".join(map(str, getattr(exc, "absolute_path", [])))
        raise ContractError("SCHEMA_VALIDATION", f"{path}: {getattr(exc, 'message', str(exc))}") from exc


class CapabilityRegistry:
    def __init__(self, directory=None):
        directory = Path(directory) if directory else ROOT / "capabilities"
        self._items = {}
        methods = set()
        manifest_schema = load_schema("capability.schema.json")
        for path in sorted(directory.glob("*.json")):
            document = json.loads(path.read_text())
            if isinstance(document, list):
                entries = document
            elif "capabilities" in document:
                entries = document["capabilities"]
            else:
                entries = [document]
            for entry in entries:
                item = copy.deepcopy(entry)
                validate(manifest_schema, item)
                check_schema(item["input_schema"])
                check_schema(item["output_schema"])
                if item["name"] in self._items:
                    raise ContractError("DUPLICATE_CAPABILITY", item["name"])
                if item.get("method") and not item["method"].startswith("v4."):
                    raise ContractError("UNSAFE_CAPABILITY", "Native capabilities must use the v4 namespace")
                if item.get("method"):
                    if item["method"] in methods:
                        raise ContractError("DUPLICATE_CAPABILITY", item["method"])
                    methods.add(item["method"])
                item["schema_hash"] = digest(item)
                self._items[item["name"]] = item

    def get(self, name):
        if name not in self._items:
            raise ContractError("UNSUPPORTED_CAPABILITY", name)
        return copy.deepcopy(self._items[name])

    def search(self, query="", category=None, limit=10):
        if not isinstance(limit, int) or isinstance(limit, bool) or not 1 <= limit <= 50:
            raise ContractError("SCHEMA_VALIDATION", "limit must be between 1 and 50")
        terms = query.lower().split()
        matches = []
        for name, item in sorted(self._items.items()):
            text = " ".join((name, item["description"], item.get("category", ""))).lower()
            if category and category != item.get("category", name.split(".")[0]):
                continue
            if all(term in text for term in terms):
                matches.append({key: copy.deepcopy(item[key]) for key in (
                    "name", "description", "schema_hash", "backend", "requires_fcp_build",
                    "evidence_level", "known_limitations")})
        return {"matches": matches[:limit], "total": len(matches), "truncated": len(matches) > limit}

    def supported(self, name, build):
        scope = self.get(name)["requires_fcp_build"]
        return "*" in scope or (bool(build) and build != "unknown" and build in scope)

    def __len__(self):
        return len(self._items)
