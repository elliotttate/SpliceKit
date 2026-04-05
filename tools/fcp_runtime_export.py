#!/usr/bin/env python3
"""
fcp_runtime_export.py — Export ObjC runtime metadata from a live FCP process via SpliceKit.

Connects to SpliceKit's JSON-RPC server (TCP 127.0.0.1:9876) and dumps full class metadata
for every loaded Mach-O image into per-binary JSON files. The output is consumed by
ida_import_runtime.py to enrich IDA Pro decompilation.

Usage:
    python3 fcp_runtime_export.py                          # export all images
    python3 fcp_runtime_export.py --binary Flexo            # export one binary
    python3 fcp_runtime_export.py --binary Flexo --binary TLKit  # export specific binaries
    python3 fcp_runtime_export.py --classes-only            # fast: just class names
    python3 fcp_runtime_export.py --output /path/to/dir     # custom output directory

Output structure:
    output_dir/
      _image_map.json          — {name: {path, baseAddress, slide, classCount}} for all images
      Flexo.json               — full metadata for classes in Flexo
      TLKit.json               — full metadata for classes in TLKit
      ...
"""

import argparse
import json
import os
import socket
import sys
import time


def rpc_call(method: str, params: dict = None, host: str = "127.0.0.1", port: int = 9876) -> dict:
    """Send a JSON-RPC 2.0 request and return the result."""
    request = {
        "jsonrpc": "2.0",
        "id": 1,
        "method": method,
        "params": params or {}
    }
    payload = json.dumps(request) + "\n"

    sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    sock.settimeout(300)  # 5 min timeout for large dumps
    sock.connect((host, port))

    try:
        sock.sendall(payload.encode("utf-8"))

        # Read response (may be very large)
        chunks = []
        while True:
            chunk = sock.recv(1024 * 1024)  # 1MB chunks
            if not chunk:
                break
            chunks.append(chunk)
            # JSON-RPC responses are newline-delimited
            if b"\n" in chunk:
                break

        raw = b"".join(chunks).decode("utf-8").strip()
        if not raw:
            return {"error": "Empty response from SpliceKit"}

        response = json.loads(raw)
        if "error" in response:
            return {"error": response["error"]}
        return response.get("result", response)
    finally:
        sock.close()


def export_image_map(host: str, port: int, output_dir: str) -> list:
    """Export the image map (all loaded Mach-O images with addresses)."""
    print("Fetching loaded image list...")
    result = rpc_call("debug.listLoadedImages", {}, host, port)

    if "error" in result:
        print(f"Error: {result['error']}", file=sys.stderr)
        sys.exit(1)

    images = result.get("images", [])
    print(f"  Found {len(images)} loaded images")

    # Build the map
    image_map = {}
    for img in images:
        image_map[img["name"]] = {
            "path": img["path"],
            "baseAddress": img["baseAddress"],
            "slide": img["slide"],
            "classCount": img["classCount"]
        }

    map_path = os.path.join(output_dir, "_image_map.json")
    with open(map_path, "w") as f:
        json.dump(image_map, f, indent=2)
    print(f"  Saved image map to {map_path}")

    return images


def export_binary(binary_name: str, host: str, port: int, output_dir: str,
                  classes_only: bool = False) -> dict:
    """Export full metadata for one binary."""
    params = {"binary": binary_name}
    if classes_only:
        params["classesOnly"] = True

    print(f"Exporting {binary_name}...", end="", flush=True)
    t0 = time.time()
    result = rpc_call("debug.dumpRuntimeMetadata", params, host, port)
    elapsed = time.time() - t0

    if "error" in result:
        print(f" ERROR: {result['error']}")
        return {"error": result["error"]}

    classes = result.get("classes", {})
    total = sum(len(v) for v in classes.values())
    print(f" {total} classes in {elapsed:.1f}s")

    # Find the matching key in classes dict
    for key, class_data in classes.items():
        out_name = key.replace(".dylib", "").replace(".framework", "")
        out_path = os.path.join(output_dir, f"{out_name}.json")

        # Include image info from the images array
        image_info = None
        for img in result.get("images", []):
            if img["name"] == key:
                image_info = img
                break

        output = {
            "binary": key,
            "image": image_info,
            "classCount": len(class_data),
            "classes": class_data
        }

        with open(out_path, "w") as f:
            json.dump(output, f, indent=2)
        print(f"  Saved {out_path} ({len(class_data)} classes)")

    return result


def export_image_sections(binary_name: str, host: str, port: int, output_dir: str):
    """Export ObjC section data (selrefs, classrefs) for one binary."""
    print(f"  Sections for {binary_name}...", end="", flush=True)
    result = rpc_call("debug.getImageSections", {"binary": binary_name}, host, port)
    if "error" in result:
        print(f" ERROR: {result.get('error')}")
        return
    sel_count = result.get("selectorRefCount", 0)
    cls_count = result.get("classRefCount", 0)
    print(f" {sel_count} selrefs, {cls_count} classrefs")

    out_name = binary_name.replace(".dylib", "").replace(".framework", "")
    out_path = os.path.join(output_dir, f"{out_name}_sections.json")
    with open(out_path, "w") as f:
        json.dump(result, f, indent=2)


def export_image_symbols(binary_name: str, host: str, port: int, output_dir: str):
    """Export symbol table for one binary."""
    print(f"  Symbols for {binary_name}...", end="", flush=True)
    result = rpc_call("debug.getImageSymbols", {"binary": binary_name}, host, port)
    if "error" in result:
        print(f" ERROR: {result.get('error')}")
        return
    count = result.get("exportedCount", 0)
    swift = result.get("swiftDemangledCount", 0)
    print(f" {count} exported ({swift} Swift demangled)")

    out_name = binary_name.replace(".dylib", "").replace(".framework", "")
    out_path = os.path.join(output_dir, f"{out_name}_symbols.json")
    with open(out_path, "w") as f:
        json.dump(result, f, indent=2)


def export_notifications(host: str, port: int, output_dir: str):
    """Export all notification name constants."""
    print("Fetching notification names...", end="", flush=True)
    result = rpc_call("debug.getNotificationNames", {}, host, port)
    if "error" in result:
        print(f" ERROR: {result.get('error')}")
        return
    count = result.get("count", 0)
    print(f" {count} notification constants")

    out_path = os.path.join(output_dir, "_notifications.json")
    with open(out_path, "w") as f:
        json.dump(result, f, indent=2)
    print(f"  Saved {out_path}")


def main():
    parser = argparse.ArgumentParser(
        description="Export ObjC runtime metadata from FCP via SpliceKit for IDA Pro")
    parser.add_argument("--host", default="127.0.0.1", help="SpliceKit host")
    parser.add_argument("--port", type=int, default=9876, help="SpliceKit port")
    parser.add_argument("--output", "-o", default="ida_export",
                        help="Output directory (default: ida_export)")
    parser.add_argument("--binary", "-b", action="append",
                        help="Binary/framework to export (can specify multiple; default: all with ObjC classes)")
    parser.add_argument("--classes-only", action="store_true",
                        help="Export only class names, not full metadata (fast)")
    parser.add_argument("--min-classes", type=int, default=1,
                        help="Skip images with fewer than N classes (default: 1)")
    parser.add_argument("--no-sections", action="store_true",
                        help="Skip Mach-O section export (selrefs, classrefs)")
    parser.add_argument("--no-symbols", action="store_true",
                        help="Skip symbol table export")
    parser.add_argument("--no-notifications", action="store_true",
                        help="Skip notification name export")
    args = parser.parse_args()

    # Create output directory
    os.makedirs(args.output, exist_ok=True)

    # Always export the image map first
    images = export_image_map(args.host, args.port, args.output)

    # Export notification names (global, not per-binary)
    if not args.no_notifications:
        export_notifications(args.host, args.port, args.output)

    if args.binary:
        # Export specific binaries
        for binary in args.binary:
            export_binary(binary, args.host, args.port, args.output, args.classes_only)
            if not args.no_sections:
                export_image_sections(binary, args.host, args.port, args.output)
            if not args.no_symbols:
                export_image_symbols(binary, args.host, args.port, args.output)
    else:
        # Export all images that have ObjC classes
        targets = [img for img in images if img["classCount"] >= args.min_classes]
        targets.sort(key=lambda x: x["classCount"], reverse=True)

        print(f"\nExporting {len(targets)} binaries with ObjC classes...")
        for i, img in enumerate(targets):
            name = img["name"]
            print(f"[{i+1}/{len(targets)}] ", end="")
            export_binary(name, args.host, args.port, args.output, args.classes_only)
            if not args.no_sections:
                export_image_sections(name, args.host, args.port, args.output)
            if not args.no_symbols:
                export_image_symbols(name, args.host, args.port, args.output)

    print(f"\nDone. Output in {os.path.abspath(args.output)}/")


if __name__ == "__main__":
    main()
