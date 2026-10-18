#!/usr/bin/env python3
"""Import generated FCPXML only into an already-open, isolated test library."""
import argparse
import hashlib
import json
from pathlib import Path
import sys
import xml.etree.ElementTree as ET

if __package__ in (None, ""):
    sys.path.insert(0, str(Path(__file__).resolve().parents[3]))

from tests.live.contract import VerificationError
from tests.live.run_live import guard, writer_lock, write_json
from tests.live.rpc import RPCClient


def install(manifest, rpc, library_path, output):
    if manifest.get("schema") != "splicekit.fixture/1" or not manifest.get("media_generated"):
        raise VerificationError("A fully generated fixture manifest is required")
    prepared = []
    latch = Path(output) / ".fixture-install-in-progress.json"
    if latch.exists():
        raise VerificationError("Previous fixture import needs manual reconciliation")
    for variant in manifest["variants"]:
        for field in ("xml", "media"):
            path = Path(variant[field])
            if hashlib.sha256(path.read_bytes()).hexdigest() != variant[field + "_sha256"]:
                raise VerificationError("Fixture content changed: " + str(path))
        tree = ET.fromstring(Path(variant["xml"]).read_text(encoding="utf-8"))
        lib = tree.find("library")
        if lib is None:
            raise VerificationError("Fixture has no library blueprint")
        lib.set("location", Path(library_path).resolve().as_uri())
        fixture = {"library_name": "SpliceKit-Test-v4", "project": variant["project"],
                   "frame_duration": variant["frame_duration"]}
        if variant["project"] not in {"SpliceKit-Test-30", "SpliceKit-Test-2997"}:
            raise VerificationError("Unexpected fixture project")
        if (Path(output) / (fixture["project"] + "-import.json")).exists():
            raise VerificationError("An import receipt already exists; do not replay fixture imports")
        prepared.append((fixture, ET.tostring(tree, encoding="unicode")))
    if not prepared:
        raise VerificationError("No fixture variants")
    write_json(latch, {"schema": "splicekit.fixture-install-latch/1", "library_path": str(library_path)})
    for fixture, xml in prepared:
        guard(rpc, fixture, library_path, check_project=False)
        result = rpc.call("fcpxml.import", {"xml": xml, "internal": True, "allowFileFallback": False})
        # An import acknowledgement is not host readback or user acceptance.
        write_json(Path(output) / (fixture["project"] + "-import.json"),
                   {"schema": "splicekit.fixture-import/1", "fixture": fixture,
                    "library_path": str(library_path), "acknowledgement": result,
                    "project_readback": "not_checked", "rpc_transcript": rpc.transcript})
    latch.unlink()


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("manifest", type=Path)
    parser.add_argument("--library-path", required=True, type=Path)
    parser.add_argument("--port", type=int, default=9876)
    args = parser.parse_args(argv)
    if not args.library_path.is_absolute():
        parser.error("An absolute library path is required")
    manifest = json.loads(args.manifest.read_text(encoding="utf-8"))
    with writer_lock(args.port):
        install(manifest, RPCClient(port=args.port), args.library_path, args.manifest.parent)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
