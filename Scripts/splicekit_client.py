#!/usr/bin/env python3
"""
FCPBridge Python Client
Connects to the FCPBridge Unix domain socket and provides
direct access to Final Cut Pro's internal APIs.
"""

import socket
import json
import sys
import readline  # enables arrow keys in interactive mode

FCPBRIDGE_HOST = "127.0.0.1"
FCPBRIDGE_PORT = 9876


class FCPBridge:
    """Client for the FCPBridge JSON-RPC server running inside Final Cut Pro."""

    def __init__(self, host=FCPBRIDGE_HOST, port=FCPBRIDGE_PORT):
        self.host = host
        self.port = port
        self.sock = None
        self._id_counter = 0
        self._buffer = b""
        self.connect()

    def connect(self):
        """Connect to the FCPBridge TCP server."""
        self.sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        self.sock.connect((self.host, self.port))
        print(f"Connected to FCPBridge at {self.host}:{self.port}")

    def close(self):
        """Close the connection."""
        if self.sock:
            self.sock.close()
            self.sock = None

    def call(self, method, **params):
        """Send a JSON-RPC request and return the result."""
        self._id_counter += 1
        request = {
            "jsonrpc": "2.0",
            "method": method,
            "params": params,
            "id": self._id_counter,
        }
        self.sock.sendall(json.dumps(request).encode() + b"\n")

        # Read response line
        while b"\n" not in self._buffer:
            chunk = self.sock.recv(1048576)
            if not chunk:
                raise ConnectionError("Server closed connection")
            self._buffer += chunk

        line, self._buffer = self._buffer.split(b"\n", 1)
        response = json.loads(line)

        if "error" in response:
            raise Exception(f"RPC Error: {response['error']}")
        return response.get("result")

    # ---- Convenience methods ----

    def version(self):
        """Get FCPBridge and FCP version info."""
        return self.call("system.version")

    def get_classes(self, filter=None):
        """List all ObjC classes, optionally filtered by substring."""
        return self.call("system.getClasses", filter=filter) if filter else self.call("system.getClasses")

    def get_methods(self, class_name, include_super=False):
        """List all methods on a class."""
        return self.call("system.getMethods", className=class_name, includeSuper=include_super)

    def call_method(self, class_name, selector, class_method=False):
        """Call a method on a class (class method) or singleton instance."""
        return self.call("system.callMethod",
                         className=class_name,
                         selector=selector,
                         classMethod=class_method)

    def get_properties(self, class_name):
        """Get declared properties of a class."""
        return self.call("system.getProperties", className=class_name)

    def get_protocols(self, class_name):
        """Get protocols adopted by a class."""
        return self.call("system.getProtocols", className=class_name)

    def get_superchain(self, class_name):
        """Get the superclass chain for a class."""
        return self.call("system.getSuperchain", className=class_name)

    def get_ivars(self, class_name):
        """Get instance variables of a class."""
        return self.call("system.getIvars", className=class_name)


def interactive_mode():
    """Run an interactive REPL for FCPBridge."""
    try:
        fcp = FCPBridge()
    except (FileNotFoundError, ConnectionRefusedError, OSError) as e:
        print(f"ERROR: Cannot connect to {FCPBRIDGE_HOST}:{FCPBRIDGE_PORT} - {e}")
        print("Make sure modded FCP is running with FCPBridge loaded.")
        sys.exit(1)

    info = fcp.version()
    print(f"\nFCPBridge v{info['fcpbridge_version']}")
    print(f"FCP {info['fcp_version']} (build {info['fcp_build']})")
    print(f"PID: {info['pid']} | Arch: {info['arch']}")
    print(f"\nType JSON-RPC method calls or use shortcuts:")
    print(f"  classes [filter]       - List classes")
    print(f"  methods <ClassName>    - List methods")
    print(f"  props <ClassName>      - List properties")
    print(f"  ivars <ClassName>      - List ivars")
    print(f"  super <ClassName>      - Show superclass chain")
    print(f"  call <Class> <sel>     - Call class method")
    print(f"  raw <json>             - Send raw JSON-RPC")
    print(f"  quit                   - Exit")
    print()

    while True:
        try:
            line = input("fcpbridge> ").strip()
        except (EOFError, KeyboardInterrupt):
            print("\nBye!")
            break

        if not line:
            continue

        try:
            parts = line.split()
            cmd = parts[0].lower()

            if cmd == "quit" or cmd == "exit":
                break
            elif cmd == "classes":
                f = parts[1] if len(parts) > 1 else None
                result = fcp.get_classes(filter=f)
                for c in result["classes"]:
                    print(f"  {c}")
                print(f"\n({result['count']} classes)")
            elif cmd == "methods":
                if len(parts) < 2:
                    print("Usage: methods <ClassName>")
                    continue
                result = fcp.get_methods(parts[1])
                print(f"\n=== {parts[1]} ===")
                print(f"\nInstance methods ({result['instanceMethodCount']}):")
                for name, info in sorted(result["instanceMethods"].items()):
                    print(f"  - {name}  ({info['typeEncoding']})")
                print(f"\nClass methods ({result['classMethodCount']}):")
                for name, info in sorted(result["classMethods"].items()):
                    print(f"  + {name}  ({info['typeEncoding']})")
            elif cmd == "props":
                if len(parts) < 2:
                    print("Usage: props <ClassName>")
                    continue
                result = fcp.get_properties(parts[1])
                for p in result["properties"]:
                    print(f"  {p['name']}: {p['attributes']}")
                print(f"\n({result['count']} properties)")
            elif cmd == "ivars":
                if len(parts) < 2:
                    print("Usage: ivars <ClassName>")
                    continue
                result = fcp.get_ivars(parts[1])
                for iv in result["ivars"]:
                    print(f"  {iv['name']}: {iv['type']}")
                print(f"\n({result['count']} ivars)")
            elif cmd == "super":
                if len(parts) < 2:
                    print("Usage: super <ClassName>")
                    continue
                result = fcp.get_superchain(parts[1])
                for i, cls in enumerate(result["superchain"]):
                    print(f"  {'  ' * i}{cls}")
            elif cmd == "call":
                if len(parts) < 3:
                    print("Usage: call <ClassName> <selector>")
                    continue
                result = fcp.call_method(parts[1], parts[2], class_method=True)
                print(json.dumps(result, indent=2))
            elif cmd == "raw":
                raw = " ".join(parts[1:])
                req = json.loads(raw)
                # Direct send
                fcp._id_counter += 1
                req["id"] = fcp._id_counter
                req["jsonrpc"] = "2.0"
                fcp.sock.sendall(json.dumps(req).encode() + b"\n")
                while b"\n" not in fcp._buffer:
                    fcp._buffer += fcp.sock.recv(1048576)
                resp_line, fcp._buffer = fcp._buffer.split(b"\n", 1)
                print(json.dumps(json.loads(resp_line), indent=2))
            elif cmd == "version":
                result = fcp.version()
                print(json.dumps(result, indent=2))
            else:
                # Try as a direct method call
                result = fcp.call(line)
                print(json.dumps(result, indent=2, default=str))

        except Exception as e:
            print(f"Error: {e}")

    fcp.close()


if __name__ == "__main__":
    if len(sys.argv) > 1 and sys.argv[1] == "--interactive":
        interactive_mode()
    elif len(sys.argv) > 1:
        # One-shot mode: fcpbridge_client.py "system.version"
        fcp = FCPBridge()
        result = fcp.call(sys.argv[1], **json.loads(sys.argv[2]) if len(sys.argv) > 2 else {})
        print(json.dumps(result, indent=2, default=str))
        fcp.close()
    else:
        interactive_mode()
