"""Bounded newline-delimited JSON-RPC client, matching SpliceKit's TCP wire format."""
import json
import socket
import time


class RPCError(RuntimeError):
    pass


class UnknownOutcome(RPCError):
    """A request may have reached the host. Never replay or blindly undo it."""


class RPCClient:
    def __init__(self, host="127.0.0.1", port=9876, timeout=10.0):
        if host != "127.0.0.1":
            raise ValueError("Only the local SpliceKit bridge is supported")
        self.host, self.port, self.timeout = host, port, timeout
        self.transcript = []
        self._id = 0

    def call(self, method, params=None):
        self._id += 1
        request = {"jsonrpc": "2.0", "id": self._id, "method": method, "params": params or {}}
        record = {"request": request}
        self.transcript.append(record)
        sent = False
        try:
            deadline = time.monotonic() + self.timeout
            with socket.create_connection((self.host, self.port), self.timeout) as conn:
                # Even partial send failure must be treated as an unknown outcome.
                sent = True
                conn.sendall(json.dumps(request, allow_nan=False).encode() + b"\n")
                buffer = b""
                received = 0
                while time.monotonic() < deadline:
                    conn.settimeout(max(0.001, deadline - time.monotonic()))
                    chunk = conn.recv(65536)
                    if not chunk:
                        raise UnknownOutcome("Bridge closed before a matching response")
                    buffer += chunk
                    received += len(chunk)
                    if received > 32 * 1024 * 1024:
                        raise UnknownOutcome("RPC response exceeded 32 MiB")
                    while b"\n" in buffer:
                        line, buffer = buffer.split(b"\n", 1)
                        if not line.strip():
                            continue
                        response = json.loads(line)
                        if not isinstance(response, dict):
                            raise UnknownOutcome("RPC response must be an object")
                        if "method" in response or response.get("id") != request["id"]:
                            record.setdefault("ignored_frames", []).append(response)
                            continue
                        record["response"] = response
                        if response.get("jsonrpc") != "2.0":
                            raise UnknownOutcome("RPC response has no JSON-RPC 2.0 version")
                        if "error" in response:
                            raise RPCError(str(response["error"]))
                        if "result" not in response:
                            raise UnknownOutcome("RPC response has no result")
                        result = response["result"]
                        if isinstance(result, dict) and result.get("error"):
                            # Preserve operation envelopes for the runner's outcome checks.
                            if "operation_id" not in result:
                                raise RPCError(str(result["error"]))
                        return result
                raise UnknownOutcome("RPC deadline elapsed")
        except (OSError, ValueError) as exc:
            record["transport_error"] = str(exc)
            if sent:
                raise UnknownOutcome(str(exc)) from exc
            raise RPCError(str(exc)) from exc
        except RPCError as exc:
            record["rpc_error"] = str(exc)
            raise
