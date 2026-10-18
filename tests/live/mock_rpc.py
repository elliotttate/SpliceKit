"""Disposable TCP fixture for the runner tests; never a production bridge adapter."""
from contextlib import contextmanager
from copy import deepcopy
import json
import socketserver
import threading


class MockBridge:
    def __init__(self, project="SpliceKit-Test-30", frame_duration="1/30s", fault=None):
        self.library_name = "SpliceKit-Test-v4"
        self.library_path = "/tmp/SpliceKit-Test-v4.fcpbundle"
        self.library_count = 1
        self.project = project
        self.frame_duration = frame_duration
        self.fault = fault
        self.calls = []
        self.state = {"opacity": 1.0, "duration": "3003/1000s" if "2997" in project else "3s",
                      "audio_linked": True, "unrelated_clip": {"name": "Keep me", "gain_db": 0}}
        self.revision = 1
        self.history = {}
        self.mutations = 0

    def envelope(self, operation_id, before, **updates):
        return {"ok": True, "operation_id": operation_id, "applied": True,
                "readback": deepcopy(self.state), "revision_before": str(before),
                "revision_after": str(self.revision),
                "undo": {"kind": "native_group", "label": "Mock fixture edit"},
                "evidence_level": "offline_tested", "warnings": [], "error": None, **updates}

    def dispatch(self, method, params):
        self.calls.append((method, deepcopy(params)))
        if method == "system.version":
            return {"fcp_version": "mock", "fcp_build": "mock-build", "splicekit_version": "mock-v4",
                    "macos_version": "mock", "arch": "mock", "simulated": True}
        if method == "object.release":
            return {"released": True}
        if method == "system.callMethodWithArgs":
            selector = params["selector"]
            if selector in {"copyActiveLibraries", "objectAtIndex:", "URL"}:
                return {"handle": "mock:" + selector}
            return {"result": {"count": self.library_count, "displayName": self.library_name,
                               "path": self.library_path}[selector]}
        if method == "timeline.getDetailedState":
            numerator, denominator = self.frame_duration[:-1].split("/")
            return {"sequenceName": self.project,
                    "frameDuration": {"value": int(numerator), "timescale": int(denominator)}}
        if method in {"v4.parameter.inspect", "v4.timeline.inspect"}:
            return {"state": deepcopy(self.state), "revision": str(self.revision), "revision_after": str(self.revision)}
        if method == "v4.media.analyze":
            return self.envelope("blocked-admission", self.revision, ok=False, applied=False,
                                 readback={"native_started": False, "ready": False},
                                 undo={"kind": "none", "label": ""},
                                 error={"code": "NOT_IMPLEMENTED", "message": "Native analysis not implemented", "retryable": False})
        if method in {"v4.parameter.set", "v4.timeline.trim"}:
            if params.get("expected_revision") != str(self.revision):
                raise ValueError("Stale apply revision")
            before = self.revision
            operation_id = "mock-operation-" + str(before)
            self.history[operation_id] = deepcopy(self.state)
            self.mutations += 1
            if self.fault != "no_change":
                if method == "v4.parameter.set":
                    self.state[params["property"]] = params["value"]
                else:
                    self.state["duration"] = params["duration"]
            self.revision += 1
            envelope = self.envelope(operation_id, before)
            if self.fault == "lie":
                self.state = deepcopy(self.history[operation_id])
            if self.fault == "bad_envelope":
                del envelope["undo"]
            if self.fault == "unknown":
                envelope["applied"] = None
            if self.fault == "revision_drift":
                self.revision += 1
            return envelope
        if method == "v4.operation.undo":
            if params.get("expected_revision") != str(self.revision):
                raise ValueError("Stale undo revision")
            before = self.revision
            self.state = self.history.pop(params["operation_id"])
            if self.fault == "dirty_undo":
                self.state["unrelated_clip"]["gain_db"] = -6
            self.revision += 1
            return self.envelope("undo:" + params["operation_id"], before)
        raise ValueError("Method not found: " + method)


@contextmanager
def mock_server(bridge):
    class Handler(socketserver.StreamRequestHandler):
        def handle(self):
            request = json.loads(self.rfile.readline())
            method = request["method"]
            try:
                result = bridge.dispatch(method, request.get("params", {}))
                if bridge.fault == "disconnect" and method == "v4.parameter.set":
                    return  # Mutation applied, but its acknowledgement is lost.
                if bridge.fault == "timeout" and method == "v4.parameter.set":
                    threading.Event().wait(0.2)
                    return
                response = {"jsonrpc": "2.0", "id": request["id"], "result": result}
            except ValueError as exc:
                response = {"jsonrpc": "2.0", "id": request["id"],
                            "error": {"code": -32000, "message": str(exc)}}
            try:
                # Notifications and stale replies must not count as acknowledgements.
                self.wfile.write(json.dumps({"jsonrpc": "2.0", "method": "event", "params": {}}).encode() + b"\n")
                self.wfile.write(json.dumps({"jsonrpc": "2.0", "id": -1, "result": {}}).encode() + b"\n")
                encoded = json.dumps(response).encode() + b"\n"
                self.wfile.write(encoded[:7])
                self.wfile.flush()
                self.wfile.write(encoded[7:])
            except (BrokenPipeError, ConnectionResetError):
                pass

    with socketserver.TCPServer(("127.0.0.1", 0), Handler) as server:
        thread = threading.Thread(target=server.serve_forever, kwargs={"poll_interval": 0.01}, daemon=True)
        thread.start()
        try:
            yield server.server_address[1]
        finally:
            server.shutdown()
            thread.join(timeout=2)
