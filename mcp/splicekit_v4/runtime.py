"""One serialized Python entry point; cross-client ownership belongs to native core."""

import copy
import threading
import uuid

from . import EVIDENCE_LEVELS
from .contracts import ContractError, failure, result
from .registry import CapabilityRegistry, load_schema, validate

BINDINGS = {
    "state.read": ("state.read", "core.state.read", "v4.state.revision"),
    "operation.status": ("operation.status", "core.operation.status", "v4.operation.status", "v4.core.operation.status"),
    "history.checkpoint": ("history.checkpoint", "core.history.checkpoint", "v4.history.checkpoint", "v4.core.history.checkpoint"),
    "history.restore": ("history.restore", "core.history.restore", "v4.history.restore", "v4.core.history.restore"),
}


class AgentRuntime:
    def __init__(self, bridge, registry=None, artifact_directory=None):
        self.bridge = bridge
        self.registry = registry if registry is not None else CapabilityRegistry()
        self.artifact_directory = artifact_directory
        self.lock = threading.RLock()
        self.discovered, self.described = set(), {}
        self.operations, self.plans, self.unknown = {}, {}, set()
        from .plans import PlanEngine
        self.engine = PlanEngine(self)

    @staticmethod
    def operation_id(key):
        return str(uuid.uuid5(uuid.NAMESPACE_URL, "splicekit-v4/" + key))

    def require_writable(self):
        if self.unknown:
            raise ContractError("UNKNOWN_OUTCOME", "Unresolved native operations block writes; inspect operation_status")

    def session_status(self):
        with self.lock:
            try:
                version = self.bridge.call("v4.session.status")
                if not isinstance(version, dict) or version.get("error"):
                    raise ContractError("HOST_UNAVAILABLE", str(version))
                if not version.get("ok"):
                    raise ContractError("HOST_UNAVAILABLE", str(version.get("error")))
                return result(readback={"host": version["readback"], "capability_count": len(self.registry),
                                        "unknown_operations": sorted(self.unknown),
                                        "evidence_levels": list(EVIDENCE_LEVELS),
                                        "bootstrap": "v4", "live_verification": "not_performed"})
            except Exception as exc:
                return failure(exc)

    def check_build(self, cap):
        if cap.get("local_handler"):
            return
        version = self.bridge.call("system.version")
        build = version.get("fcp_build") if isinstance(version, dict) else None
        if not self.registry.supported(cap["name"], build):
            raise ContractError("UNSUPPORTED_FCP_BUILD", f"{cap['name']}: build {build!r}, scope {cap['requires_fcp_build']}")
        if EVIDENCE_LEVELS.index(cap["evidence_level"]) < EVIDENCE_LEVELS.index("offline_tested"):
            raise ContractError("INSUFFICIENT_EVIDENCE", "Static discovery does not grant native execution")

    def capability_search(self, query="", category=None, limit=10):
        with self.lock:
            try:
                matches = self.registry.search(query, category, limit)
                self.discovered.update(item["name"] for item in matches["matches"])
                return result(readback=matches)
            except Exception as exc:
                return failure(exc)

    def capability_describe(self, name):
        with self.lock:
            try:
                if name not in self.discovered:
                    raise ContractError("DISCOVERY_REQUIRED", "Search for the capability before describing it")
                cap = self.registry.get(name)
                self.described[name] = cap["schema_hash"]
                return result(readback=cap)
            except Exception as exc:
                return failure(exc)

    def capability_invoke(self, name, arguments, schema_hash):
        with self.lock:
            try:
                cap = self.registry.get(name)
                if self.described.get(name) != schema_hash or schema_hash != cap["schema_hash"]:
                    raise ContractError("DESCRIPTION_REQUIRED", "Search and describe the current capability schema first")
                validate(cap["input_schema"], arguments)
                handler = cap.get("local_handler")
                if handler == "plan.validate":
                    return result(readback=self.engine.validate(arguments["plan"]))
                if handler == "plan.preview_diff":
                    return result(readback=self.engine.preview_diff(arguments["plan"]))
                if handler == "plan.apply":
                    return self.engine.apply(arguments["plan"], arguments["idempotency_key"])
                if handler == "review.capture":
                    from .review import capture
                    return capture(self, arguments["request"])
                self.require_writable() if cap.get("write_supported") else None
                return self.execute(name, arguments)
            except Exception as exc:
                return failure(exc)

    def execute(self, name, arguments):
        """Internal plan calls use the same schemas and envelope checks as direct calls."""
        cap = self.registry.get(name)
        write = cap.get("write_supported", False) or cap.get("operation_kind") == "admission"
        operation_id = arguments.get("operation_id")
        try:
            validate(cap["input_schema"], arguments)
            self.check_build(cap)
            if write:
                self.require_writable()
                if not all(arguments.get(key) for key in ("expected_revision", "operation_id")):
                    raise ContractError("OPERATION_CONTRACT_REQUIRED", "Native writes require revision and operation ID")
        except Exception as exc:
            return failure(exc, operation_id=operation_id)
        try:
            response = self.bridge.call(cap["method"], **arguments)
            validate(load_schema("result.schema.json"), response)
            validate(cap["output_schema"], response)
            if write and response["operation_id"] != operation_id:
                raise ContractError("OPERATION_ID_MISMATCH", "Native response belongs to another operation")
            if write and response.get("status") != "pending" and (response["ok"] or response["applied"] is True):
                if (response["applied"] is None or not isinstance(response["readback"], dict)
                        or response["revision_before"] != arguments["expected_revision"]
                        or not response["revision_after"]):
                    raise ContractError("APPLIED_UNVERIFIED", "Native write requires fresh readback and matching revisions")
            # Evidence cannot exceed the exact capability/build's declared level.
            response = copy.deepcopy(response)
            response["evidence_level"] = min((cap["evidence_level"], response["evidence_level"]), key=EVIDENCE_LEVELS.index)
        except Exception as exc:
            response = failure(ContractError("UNKNOWN_OUTCOME" if write else "INVALID_HOST_RESULT", str(exc)),
                               applied=None if write else False, operation_id=operation_id)
        if write and response["applied"] is None:
            self.unknown.add(response["operation_id"])
        self.operations[response["operation_id"]] = copy.deepcopy(response)
        return response

    def require_binding(self, logical_name):
        for name in BINDINGS[logical_name]:
            try:
                cap = self.registry.get(name)
            except ContractError:
                continue
            if not cap.get("method"):
                continue
            return cap
        raise ContractError("UNSUPPORTED_CAPABILITY", f"Native core binding {logical_name} is not installed")

    def bootstrap(self, logical_name, arguments=None):
        """Fixed bootstrap binding, never a caller-supplied RPC method."""
        try:
            cap = self.require_binding(logical_name)
            arguments = dict(arguments or {})
            if cap.get("write_supported"):
                # Native bootstrap writes get the same identity contract as plan steps.
                key = str(uuid.uuid4())
                arguments.update(operation_id=self.operation_id(key), idempotency_key=key)
            return self.execute(cap["name"], arguments)
        except Exception as exc:
            return failure(exc)

    def state_read(self):
        with self.lock:
            return self.bootstrap("state.read")

    def state_data(self):
        response = self.state_read()
        if not response["ok"] or not isinstance(response["readback"], dict):
            error = response.get("error") or {}
            raise ContractError(error.get("code", "STATE_UNAVAILABLE"), error.get("message", "No native state readback"))
        return response["readback"]

    @staticmethod
    def assert_identity(state, project_id, sequence_id, revision):
        if not state.get('project_id') or not state.get('sequence_id'):
            raise ContractError('UNSUPPORTED_STATE_CONTRACT', 'The native state provider does not attest project/sequence identity for this operation')
        if state.get("project_id") != project_id or state.get("sequence_id") != sequence_id:
            raise ContractError("TARGET_MISMATCH", "Fresh state belongs to another project or sequence")
        if state.get("revision") != revision:
            raise ContractError("STALE_REVISION", "Fresh native revision differs from the request")

    def operation_status(self, operation_id):
        with self.lock:
            # Read the native ledger first: the Python cache cannot reconcile a timeout.
            remote = self.bootstrap("operation.status", {"operation_id": operation_id})
            cached = self.operations.get(operation_id)
            data = remote.get("readback") or {}
            operation = data.get("result", data.get("operation"))
            settled = data.get("state") in {"COMPLETED", "FAILED", "RECONCILED"} or data.get("reconciled") is True
            if remote["ok"] and settled and isinstance(operation, dict):
                try:
                    validate(load_schema("result.schema.json"), operation)
                    if (operation["operation_id"] == operation_id and operation["applied"] is not None
                            and (not operation["applied"] or (operation["readback"] is not None and operation["revision_after"]))):
                        self.unknown.discard(operation_id)
                        self.operations[operation_id] = copy.deepcopy(operation)
                except ContractError:
                    pass # An incomplete ledger response is never reconciliation.
            if cached and (not remote["ok"] or operation is None):
                return result(readback={"source": "session_cache", "operation": cached,
                                        "reconciled": False}, warnings=["Native ledger unavailable; cache is not reconciliation."])
            return remote

    def history_checkpoint(self, label, project_id, sequence_id, expected_revision):
        with self.lock:
            try:
                self.require_writable()
                state = self.state_data()
                self.assert_identity(state, project_id, sequence_id, expected_revision)
                return self.bootstrap("history.checkpoint", {
                    "label": label, "project_id": project_id, "sequence_id": sequence_id,
                    "expected_revision": expected_revision})
            except Exception as exc:
                return failure(exc)
