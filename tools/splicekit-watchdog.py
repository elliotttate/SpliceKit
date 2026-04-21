#!/usr/bin/env python3
"""
splicekit-watchdog.py — FCP+SpliceKit crash watchdog.

Runs outside FCP. Heartbeats `bridge.alive`, subscribes to `command.*` events,
and watches ~/Library/Logs/DiagnosticReports for fresh Final Cut Pro .ips files.
When FCP dies or the bridge goes silent, it correlates the crash with the last
in-flight RPC and writes a structured crash report.

    ./splicekit-watchdog.py                     # run forever, crash reports to ~/Library/Logs/SpliceKit/watchdog/
    ./splicekit-watchdog.py --relaunch-fcp      # also relaunch FCP after a crash
    ./splicekit-watchdog.py --heartbeat 2       # check every 2 seconds (default 5)
    ./splicekit-watchdog.py --history           # print past crashes and exit

Design:
- Connects to 127.0.0.1:9876 persistently
- Every N seconds, calls `bridge.alive` with short timeout
- Also subscribes to events (command.completed, crash.*) and tracks in-flight RPCs
- On heartbeat miss: assume FCP is either in a long main-thread block or crashed;
  look for a .ips dated in the last 60s. If found, write a correlated crash report.
- Relaunch logic is optional and conservative — user must opt in.
"""

from __future__ import annotations

import argparse
import json
import os
import plistlib
import socket
import subprocess
import sys
import time
from datetime import datetime, timedelta
from pathlib import Path
from typing import Any

HOST = "127.0.0.1"
PORT = 9876
DEFAULT_HEARTBEAT_SEC = 5
CRASH_SCAN_WINDOW_SEC = 120
REPORT_DIR = Path.home() / "Library" / "Logs" / "SpliceKit" / "watchdog"
DIAGNOSTIC_REPORT_DIR = Path.home() / "Library" / "Logs" / "DiagnosticReports"


class BridgeClient:
    """Minimal persistent JSON-RPC client — no external deps."""

    def __init__(self, timeout: float = 3.0) -> None:
        self.sock: socket.socket | None = None
        self.timeout = timeout
        self._buf = b""
        self._id = 0

    def connect(self) -> bool:
        try:
            self.sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
            self.sock.settimeout(self.timeout)
            self.sock.connect((HOST, PORT))
            self._buf = b""
            return True
        except OSError:
            self.sock = None
            return False

    def close(self) -> None:
        if self.sock:
            try:
                self.sock.close()
            finally:
                self.sock = None

    def call(self, method: str, **params: Any) -> dict[str, Any]:
        if not self.sock and not self.connect():
            return {"error": "bridge unreachable"}
        self._id += 1
        req = json.dumps({"jsonrpc": "2.0", "method": method, "params": params, "id": self._id}) + "\n"
        try:
            assert self.sock
            self.sock.sendall(req.encode())
            while b"\n" not in self._buf:
                chunk = self.sock.recv(65536)
                if not chunk:
                    self.close()
                    return {"error": "connection closed"}
                self._buf += chunk
            line, self._buf = self._buf.split(b"\n", 1)
            resp = json.loads(line)
            if "error" in resp:
                return {"error": resp["error"]}
            return resp.get("result", {})
        except (OSError, socket.timeout) as exc:
            self.close()
            return {"error": f"bridge io: {exc}"}


def find_recent_fcp_crash(window_sec: int = CRASH_SCAN_WINDOW_SEC) -> Path | None:
    """Return the most recent Final Cut Pro .ips in the last `window_sec` seconds."""
    if not DIAGNOSTIC_REPORT_DIR.is_dir():
        return None
    cutoff = datetime.now() - timedelta(seconds=window_sec)
    candidates: list[tuple[float, Path]] = []
    for p in DIAGNOSTIC_REPORT_DIR.glob("Final Cut Pro-*.ips"):
        try:
            mtime = p.stat().st_mtime
        except OSError:
            continue
        if datetime.fromtimestamp(mtime) >= cutoff:
            candidates.append((mtime, p))
    if not candidates:
        return None
    candidates.sort(reverse=True)
    return candidates[0][1]


def parse_ips_summary(path: Path) -> dict[str, Any]:
    """Pull the top-of-crash summary from an .ips file.

    .ips files have a single-line JSON header followed by a JSON body. We parse
    both and return the highlights — exception type, faulting thread, and the
    top few stack frames.
    """
    try:
        text = path.read_text(errors="replace")
    except OSError as exc:
        return {"error": f"read {path}: {exc}"}
    lines = text.split("\n", 1)
    if len(lines) < 2:
        return {"error": "malformed ips"}
    try:
        header = json.loads(lines[0])
        body = json.loads(lines[1])
    except json.JSONDecodeError as exc:
        return {"error": f"parse: {exc}"}
    exc_info = body.get("exception", {})
    faulting_thread_idx = body.get("faultingThread")
    threads = body.get("threads", [])
    top_frames: list[str] = []
    if isinstance(faulting_thread_idx, int) and 0 <= faulting_thread_idx < len(threads):
        frames = threads[faulting_thread_idx].get("frames", [])
        images = body.get("usedImages", [])
        for frame in frames[:12]:
            img_idx = frame.get("imageIndex")
            symbol = frame.get("symbol") or "?"
            offset = frame.get("symbolLocation") or 0
            image_name = images[img_idx].get("name") if isinstance(img_idx, int) and img_idx < len(images) else "?"
            top_frames.append(f"{image_name}`{symbol}+{offset}")
    return {
        "path": str(path),
        "timestamp": header.get("timestamp") or header.get("captureTime"),
        "app_version": header.get("app_version"),
        "os_version": header.get("os_version"),
        "exception_type": exc_info.get("type"),
        "exception_signal": exc_info.get("signal"),
        "faulting_thread": faulting_thread_idx,
        "top_frames": top_frames,
    }


def ensure_report_dir() -> None:
    REPORT_DIR.mkdir(parents=True, exist_ok=True)


def write_crash_report(info: dict[str, Any]) -> Path:
    ensure_report_dir()
    stamp = datetime.now().strftime("%Y%m%d-%H%M%S")
    dest = REPORT_DIR / f"crash_{stamp}.json"
    dest.write_text(json.dumps(info, indent=2, default=str))
    return dest


def relaunch_fcp() -> bool:
    """Relaunch the modded FCP. Looks for the shim under ~/Applications/SpliceKit."""
    candidates = [
        Path.home() / "Applications" / "SpliceKit" / "Final Cut Pro.app",
        Path.home() / "Applications" / "SpliceKit" / "Final Cut Pro Creator Studio.app",
    ]
    for app in candidates:
        if app.exists():
            try:
                subprocess.Popen(["open", str(app)])
                return True
            except OSError:
                return False
    return False


def print_history() -> int:
    if not REPORT_DIR.is_dir():
        print("(no crash history yet)")
        return 0
    reports = sorted(REPORT_DIR.glob("crash_*.json"))
    if not reports:
        print("(no crash history yet)")
        return 0
    for p in reports:
        try:
            data = json.loads(p.read_text())
        except (OSError, json.JSONDecodeError):
            continue
        when = data.get("watchdog_detected_at", "")
        method = (data.get("in_flight_at_miss", {}) or {}).get("method") or "(no RPC in flight)"
        crash = data.get("crash") or {}
        top = (crash.get("top_frames") or ["(no frames)"])[0]
        print(f"{when}  method={method}  fault={crash.get('exception_type','?')}  top={top}")
    return 0


def run(args: argparse.Namespace) -> int:
    if args.history:
        return print_history()

    ensure_report_dir()
    client = BridgeClient(timeout=3.0)
    in_flight: dict[str, Any] | None = None
    last_alive = time.time()
    print(f"[watchdog] heartbeat={args.heartbeat}s reports={REPORT_DIR}")

    while True:
        try:
            status = client.call("bridge.alive")
            async_state = client.call("async.status")
            if "error" in status:
                print(f"[watchdog] bridge.alive error: {status['error']}")
                # Give FCP a grace window — maybe it's restarting or briefly stalled.
                if time.time() - last_alive > args.heartbeat * 3:
                    ips = find_recent_fcp_crash()
                    report: dict[str, Any] = {
                        "watchdog_detected_at": datetime.now().isoformat(),
                        "in_flight_at_miss": in_flight,
                        "last_alive_ago_sec": round(time.time() - last_alive, 1),
                        "crash": parse_ips_summary(ips) if ips else None,
                    }
                    dest = write_crash_report(report)
                    print(f"[watchdog] wrote crash report: {dest}")
                    if args.relaunch_fcp:
                        print("[watchdog] relaunching FCP...")
                        relaunch_fcp()
                    # Reset tracking
                    in_flight = None
                    last_alive = time.time()
            else:
                last_alive = time.time()
                ops = async_state.get("in_flight") or []
                in_flight = ops[0] if ops else None
        except Exception as exc:
            print(f"[watchdog] unexpected: {exc}")
        time.sleep(args.heartbeat)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="SpliceKit watchdog")
    parser.add_argument("--heartbeat", type=float, default=DEFAULT_HEARTBEAT_SEC,
                        help="seconds between bridge.alive probes")
    parser.add_argument("--relaunch-fcp", action="store_true",
                        help="relaunch FCP after a crash is detected")
    parser.add_argument("--history", action="store_true",
                        help="print past crash reports and exit")
    args = parser.parse_args(argv)
    try:
        return run(args)
    except KeyboardInterrupt:
        print("\n[watchdog] stopped")
        return 0


if __name__ == "__main__":
    sys.exit(main())
