"""Minimal JSON-RPC client for examples; one dispatch, no automatic retries."""

import itertools
import json
import socket


class TCPBridge:
    def __init__(self, host="127.0.0.1", port=9876, timeout=30):
        self.host, self.port, self.timeout = host, port, timeout
        self.ids = itertools.count(1)

    def call(self, method, **params):
        request_id = next(self.ids)
        request = {"jsonrpc": "2.0", "id": request_id, "method": method, "params": params}
        with socket.create_connection((self.host, self.port), self.timeout) as connection:
            connection.sendall(json.dumps(request, allow_nan=False).encode() + b"\n")
            pending = b""
            while True:
                chunk = connection.recv(65536)
                if not chunk:
                    raise ConnectionError("Bridge closed before matching response; do not replay writes")
                pending += chunk
                if len(pending) > 16 * 1024 * 1024:
                    raise ValueError("Bridge response exceeded the bounded example context")
                while b"\n" in pending:
                    line, pending = pending.split(b"\n", 1)
                    if not line.strip():
                        continue
                    response = json.loads(line)
                    if response.get("id") != request_id or "method" in response:
                        continue
                    if response.get("error"):
                        return {"error": response["error"]}
                    return response.get("result", {})
