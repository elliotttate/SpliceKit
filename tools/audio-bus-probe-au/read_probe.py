#!/usr/bin/env python3
import argparse
import json
import sys
from pathlib import Path


DEFAULT_STATUS = Path("/tmp/splicekit-audio-bus-probe-latest.json")
DEFAULT_GLOB = "/tmp/splicekit-audio-bus-probe-*.json"


def load_status(path):
    payload = json.loads(path.read_text(encoding="utf-8"))
    payload["_statusPath"] = str(path)
    payload["_mtimeNs"] = path.stat().st_mtime_ns
    return payload


def load_default_statuses():
    statuses = []
    for path in Path("/tmp").glob("splicekit-audio-bus-probe-*.json"):
        if path.name == DEFAULT_STATUS.name:
            continue
        try:
            statuses.append(load_status(path))
        except (OSError, json.JSONDecodeError):
            continue
    if statuses:
        return statuses
    try:
        return [load_status(DEFAULT_STATUS)]
    except FileNotFoundError:
        return []


def status_rank(payload):
    return (
        int(payload.get("renderCount", 0)),
        int(payload.get("nonSilentRenderCount", 0)),
        float(payload.get("peak", 0.0)),
        int(payload.get("_mtimeNs", 0)),
    )


def print_status(payload):
    print(f"statusPath: {payload.get('_statusPath', DEFAULT_STATUS)}")
    for key in (
        "plugin",
        "pid",
        "instance",
        "receivingAudio",
        "renderCount",
        "nonSilentRenderCount",
        "silentRenderCount",
        "lastRenderAgeMs",
        "lastFrames",
        "maxFrames",
        "channels",
        "sampleRate",
        "peak",
        "rms",
        "avgRenderMs",
        "lastRenderMs",
        "maxRenderMs",
        "cpuLoad",
        "lastError",
        "metricsPath",
    ):
        if key in payload:
            print(f"{key}: {payload[key]}")


def main():
    parser = argparse.ArgumentParser(description="Read SpliceKit Audio Bus Probe AU metrics.")
    parser.add_argument("status_path", nargs="?", help="Optional status JSON path to read directly.")
    parser.add_argument("--all", action="store_true", help="Print all probe instance summaries.")
    args = parser.parse_args()

    if args.status_path:
        try:
            statuses = [load_status(Path(args.status_path))]
        except FileNotFoundError:
            print(f"No probe status found at {args.status_path}")
            return 1
    else:
        statuses = load_default_statuses()

    if not statuses:
        print(f"No probe status found at {DEFAULT_STATUS} or {DEFAULT_GLOB}")
        return 1

    if args.all:
        for index, payload in enumerate(sorted(statuses, key=status_rank, reverse=True), 1):
            if index > 1:
                print()
            print_status(payload)
        return 0

    print_status(max(statuses, key=status_rank))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
