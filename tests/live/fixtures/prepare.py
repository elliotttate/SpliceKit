#!/usr/bin/env python3
"""Generate original media + FCPXML library/project fixtures without starting FCP."""
import argparse
from fractions import Fraction
import hashlib
import json
from pathlib import Path
import subprocess
import sys
import xml.etree.ElementTree as ET

if __package__ in (None, ""):
    sys.path.insert(0, str(Path(__file__).resolve().parents[3]))

from tests.live.run_live import write_json

HERE = Path(__file__).resolve().parent


def fcpxml(media, library, rate):
    step, scale, suffix = (1, 30, "30") if rate == "30" else (1001, 30000, "2997")
    duration = Fraction(90 * step, scale)
    time = f"{duration.numerator}/{duration.denominator}s"
    root = ET.Element("fcpxml", version="1.10")
    resources = ET.SubElement(root, "resources")
    ET.SubElement(resources, "format", id="r1", width="360", height="640",
                  frameDuration=f"{step}/{scale}s", colorSpace="1-1-1 (Rec. 709)")
    asset = ET.SubElement(resources, "asset", id="r2", name="Generated bars and tone",
                          start="0s", duration=time, hasVideo="1", hasAudio="1",
                          audioSources="1", audioChannels="1", audioRate="48000", format="r1")
    ET.SubElement(asset, "media-rep", kind="original-media", src=Path(media).resolve().as_uri())
    lib = ET.SubElement(root, "library", location=Path(library).resolve().as_uri())
    event = ET.SubElement(lib, "event", name="SpliceKit-Test-Fixtures")
    project = ET.SubElement(event, "project", name="SpliceKit-Test-" + suffix)
    sequence = ET.SubElement(project, "sequence", format="r1", duration=time, tcStart="0s",
                             tcFormat="NDF", audioLayout="mono", audioRate="48k")
    spine = ET.SubElement(sequence, "spine")
    ET.SubElement(spine, "asset-clip", ref="r2", name="Bars counter tone", offset="0s",
                  start="0s", duration=time, audioRole="dialogue")
    ET.indent(root)
    return '<?xml version="1.0" encoding="UTF-8"?>\n<!DOCTYPE fcpxml>\n' + ET.tostring(root, encoding="unicode") + "\n"


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True, help="Fresh directory; existing files are never replaced")
    parser.add_argument("--xml-only", action="store_true", help="Generate references only; do not claim media exists")
    args = parser.parse_args(argv)
    output = args.output.expanduser().resolve()
    output.mkdir(parents=True, exist_ok=False)
    library = output / "SpliceKit-Test-v4.fcpbundle"
    generator = output / "generate-media"
    if not args.xml_only:
        subprocess.run(["swiftc", str(HERE / "generate_media.swift"), "-o", str(generator)], check=True)
    manifest = {"schema": "splicekit.fixture/1", "library": str(library),
                "library_created": False, "media_generated": not args.xml_only,
                "generator_sha256": hashlib.sha256((HERE / "generate_media.swift").read_bytes()).hexdigest(),
                "variants": []}
    for rate, scale, step, duration in [("30", "30", "1", "1/30s"), ("2997", "30000", "1001", "1001/30000s")]:
        media = output / f"bars-{rate}.mov"
        if not args.xml_only:
            subprocess.run([str(generator), str(media), scale, step], check=True, timeout=90)
        xml = output / f"fixture-{rate}.fcpxml"
        xml.write_text(fcpxml(media, library, rate), encoding="utf-8")
        manifest["variants"].append({"project": "SpliceKit-Test-" + rate,
                                     "frame_duration": duration, "xml": str(xml), "media": str(media),
                                     "xml_sha256": hashlib.sha256(xml.read_bytes()).hexdigest(),
                                     "media_sha256": hashlib.sha256(media.read_bytes()).hexdigest() if media.exists() else None})
    write_json(output / "manifest.json", manifest)
    print(output / "manifest.json")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
