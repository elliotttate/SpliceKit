"""Deterministic mock, never a native FCP adapter or a production capability."""

import copy
import json
import shutil
import struct
import zlib
from pathlib import Path

from splicekit_v4.contracts import result
from splicekit_v4.registry import CapabilityRegistry
from splicekit_v4.runtime import AgentRuntime

FIXTURES = Path(__file__).parent / "fixtures"


def example_plan():
    return json.loads((FIXTURES / "edit-plan.json").read_text())


def png():
    """A real 1x1 PNG fixture, explicitly synthetic in the dry-run report."""
    def chunk(kind, data):
        return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data))
    return (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", 1, 1, 8, 2, 0, 0, 0))
            + chunk(b"IDAT", zlib.compress(b"\0\x20\x40\x60")) + chunk(b"IEND", b""))


class OfflineHost:
    def __init__(self):
        plan = example_plan()
        self.state = {"project_id": plan["project_id"], "sequence_id": plan["sequence_id"], "revision": "r0",
                      "evidence_origin": "synthetic_fixture",
                      "sources": plan["sources"], "target_ids": plan["scope"]["target_ids"], "frame_rate": plan["frame_rate"],
                      "playing": False, "viewer_ready": True, "viewer_sequence_id": plan["sequence_id"],
                      "playhead": {"num": 0, "den": 1}, "proxy_status": "fixture", "changes": []}
        self.calls, self.checkpoints, self.ledger = [], {}, {}
        self.fail_method, self.timeout_method, self.bad_readback = None, None, False

    def call(self, method, **args):
        self.calls.append((method, copy.deepcopy(args)))
        if method == "system.version":
            return {"fcp_build": "fixture-build", "fcp_version": "mock", "splicekit_version": "offline-fixture"}
        if method == "viewer.capture":
            Path(args["path"]).write_bytes(png())
            return {"status": "ok", "path": args["path"], "width": 1, "height": 1,
                    "cropped": True, "capture": {"selectedViewer": "normal"}}
        name = method.removeprefix("v4.fixture.")
        before = self.state["revision"]
        if name == "state.read":
            return result(readback=copy.deepcopy(self.state))
        if name == "operation.status":
            return result(readback={"operation": copy.deepcopy(self.ledger.get(args["operation_id"])),
                                    "reconciled": False})
        if name == "history.checkpoint":
            checkpoint_id = "cp-" + str(len(self.checkpoints))
            self.checkpoints[checkpoint_id] = copy.deepcopy(self.state)
            return result(readback={"checkpoint_id": checkpoint_id, "restorable": True, "revision": before})
        if method == self.timeout_method:
            raise TimeoutError("Injected timeout after dispatch; outcome unknown")
        if method == self.fail_method:
            return result(False, operation_id=args["operation_id"], code="INJECTED_FAILURE", message="Known no-op failure")
        operation_id = args["operation_id"]
        if operation_id in self.ledger:
            return copy.deepcopy(self.ledger[operation_id])
        if args["expected_revision"] != before:
            return result(False, operation_id=operation_id, code="STALE_REVISION", message="Revision changed")
        if name == "history.restore":
            self.state = copy.deepcopy(self.checkpoints[args["checkpoint_id"]])
        else:
            self.state["changes"].append({"method": name, "args": copy.deepcopy(args)})
            self.state["revision"] = "r" + str(len(self.state["changes"]))
        response = result(operation_id=operation_id, applied=True, readback=None if self.bad_readback else copy.deepcopy(self.state),
                          before=before, after=self.state["revision"])
        response["undo"] = {"kind": "native_group", "label": name}
        self.ledger[operation_id] = copy.deepcopy(response)
        return response


def make_runtime(directory):
    """Copy mock descriptors into an isolated registry, never into the shipped catalog."""
    directory = Path(directory)
    directory.mkdir(parents=True, exist_ok=True)
    shutil.copy(FIXTURES / "native-capabilities.json", directory / "fixture.json")
    from splicekit_v4.registry import ROOT
    shutil.copy(ROOT / "capabilities" / "agent.json", directory / "agent.json")
    host = OfflineHost()
    return AgentRuntime(host, CapabilityRegistry(directory), directory / "artifacts"), host
