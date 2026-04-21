"""
ida_targeted_slice.py -- Headless IDAPython targeted decompiler for focused RE slices.

This script is built for large binaries where "decompile everything" is wasteful.
It identifies functions related to caller-supplied patterns using:
  - function names
  - string references
  - imported symbol names

It then expands to callers/callees for a small neighborhood and decompiles only
that subgraph.

Environment variables:
    TARGET_PATTERNS       Comma-separated patterns to match (required)
    TARGET_OUTPUT_DIR     Directory for outputs (default: /tmp/ida_targeted)
    TARGET_MAX_CALL_DEPTH Caller/callee traversal depth (default: 1)
    TARGET_MAX_FUNCTIONS  Soft cap after expansion (default: 400)
"""

import json
import os
import re
import time

import ida_auto
import ida_bytes
import ida_funcs
import ida_hexrays
import ida_name
import ida_nalt
import ida_segment
import idautils


PATTERNS = [
    p.strip().lower()
    for p in os.environ.get("TARGET_PATTERNS", "").split(",")
    if p.strip()
]
OUTPUT_DIR = os.environ.get("TARGET_OUTPUT_DIR", "/tmp/ida_targeted")
MAX_CALL_DEPTH = int(os.environ.get("TARGET_MAX_CALL_DEPTH", "1"))
MAX_FUNCTIONS = int(os.environ.get("TARGET_MAX_FUNCTIONS", "400"))


def sanitize_filename(name):
    for ch in '/\\:*?"<>|':
        name = name.replace(ch, "_")
    return name[:200]


def function_name(ea):
    return ida_name.get_ea_name(ea) or f"sub_{ea:X}"


def function_for_ea(ea):
    func = ida_funcs.get_func(ea)
    return func.start_ea if func else None


def strings_iter():
    try:
        s = idautils.Strings()
        s.setup(strtypes=[0, 1, 2, 3, 4, 5], minlen=4)
        for item in s:
            yield item
    except Exception:
        return


def string_text(item):
    try:
        value = str(item)
    except Exception:
        try:
            value = item.str()
        except Exception:
            value = ""
    return value or ""


def matching_string_hits():
    hits = []
    for item in strings_iter() or []:
        text = string_text(item)
        lower = text.lower()
        if any(p in lower for p in PATTERNS):
            hits.append({
                "ea": item.ea,
                "text": text,
            })
    return hits


def matching_named_functions():
    hits = []
    for ea in idautils.Functions():
        name = function_name(ea)
        lname = name.lower()
        if any(p in lname for p in PATTERNS):
            hits.append(ea)
    return hits


def matching_imports():
    matched = []
    qty = ida_nalt.get_import_module_qty()
    for i in range(qty):
        name = ida_nalt.get_import_module_name(i) or f"import_{i}"

        def callback(ea, imp_name, ordinal):
            imp = imp_name or ""
            if any(p in imp.lower() for p in PATTERNS):
                matched.append((ea, imp, name))
            return True

        ida_nalt.enum_import_names(i, callback)
    return matched


def xref_functions_to_ea(ea):
    funcs = set()
    for ref in idautils.XrefsTo(ea):
        func_ea = function_for_ea(ref.frm)
        if func_ea is not None:
            funcs.add(func_ea)
    return funcs


def outgoing_calls(func_ea):
    out = set()
    func = ida_funcs.get_func(func_ea)
    if not func:
        return out
    for item_ea in idautils.FuncItems(func.start_ea):
        for target_ea in idautils.CodeRefsFrom(item_ea, 0):
            callee = function_for_ea(target_ea)
            if callee is not None and callee != func.start_ea:
                out.add(callee)
    return out


def incoming_calls(func_ea):
    inc = set()
    func = ida_funcs.get_func(func_ea)
    if not func:
        return inc
    for ref_ea in idautils.CodeRefsTo(func.start_ea, 0):
        caller = function_for_ea(ref_ea)
        if caller is not None and caller != func.start_ea:
            inc.add(caller)
    return inc


def collect_seed_functions():
    seeds = set(matching_named_functions())

    string_hits = matching_string_hits()
    for hit in string_hits:
        seeds.update(xref_functions_to_ea(hit["ea"]))

    import_hits = matching_imports()
    for ea, _, _ in import_hits:
        seeds.update(xref_functions_to_ea(ea))

    return seeds, string_hits, import_hits


def expand_neighbors(seeds):
    visited = set(seeds)
    frontier = set(seeds)
    graph = {}

    for depth in range(MAX_CALL_DEPTH + 1):
        next_frontier = set()
        for func_ea in frontier:
            incoming = incoming_calls(func_ea)
            outgoing = outgoing_calls(func_ea)
            graph[func_ea] = {
                "incoming": sorted(incoming),
                "outgoing": sorted(outgoing),
                "depth": depth,
            }
            if depth < MAX_CALL_DEPTH:
                next_frontier.update(incoming)
                next_frontier.update(outgoing)
        next_frontier -= visited
        if not next_frontier or len(visited) >= MAX_FUNCTIONS:
            break
        visited.update(next_frontier)
        frontier = next_frontier

    if len(visited) > MAX_FUNCTIONS:
        visited = set(sorted(visited)[:MAX_FUNCTIONS])

    return visited, graph


def decompile_targets(targets):
    os.makedirs(OUTPUT_DIR, exist_ok=True)
    if not ida_hexrays.init_hexrays_plugin():
        raise RuntimeError("Hex-Rays decompiler not available")

    entries = []
    for ea in sorted(targets):
        name = function_name(ea)
        out_name = sanitize_filename(name)
        out_path = os.path.join(OUTPUT_DIR, f"{out_name}.c")
        status = "failed"
        error = None
        try:
            cfunc = ida_hexrays.decompile(ea)
            if cfunc:
                with open(out_path, "w") as f:
                    f.write(f"// {name} @ 0x{ea:X}\n")
                    f.write(str(cfunc))
                    f.write("\n")
                status = "ok"
            else:
                error = "decompiler returned None"
        except Exception as exc:
            error = str(exc)
        entries.append({
            "ea": f"0x{ea:X}",
            "name": name,
            "file": os.path.basename(out_path),
            "status": status,
            "error": error,
        })
    return entries


def main():
    print("=" * 60)
    print("SpliceKit IDA Targeted Slice")
    print("=" * 60)
    print(f"[*] Patterns: {PATTERNS}")
    print(f"[*] Output: {OUTPUT_DIR}")
    print(f"[*] Max depth: {MAX_CALL_DEPTH}, max functions: {MAX_FUNCTIONS}")

    if not PATTERNS:
        raise RuntimeError("TARGET_PATTERNS is required")

    ida_auto.auto_wait()

    seeds, string_hits, import_hits = collect_seed_functions()
    targets, graph = expand_neighbors(seeds)

    print(f"[*] Seed functions: {len(seeds)}")
    print(f"[*] Matching strings: {len(string_hits)}")
    print(f"[*] Matching imports: {len(import_hits)}")
    print(f"[*] Expanded targets: {len(targets)}")

    start = time.time()
    entries = decompile_targets(targets)
    elapsed = time.time() - start

    ok_count = sum(1 for entry in entries if entry["status"] == "ok")
    fail_count = len(entries) - ok_count

    graph_json = {
        "patterns": PATTERNS,
        "seedCount": len(seeds),
        "targetCount": len(targets),
        "stringHits": [
            {"ea": f"0x{hit['ea']:X}", "text": hit["text"]}
            for hit in string_hits
        ],
        "importHits": [
            {"ea": f"0x{ea:X}", "name": name, "module": module}
            for ea, name, module in import_hits
        ],
        "functions": [
            {
                "ea": f"0x{ea:X}",
                "name": function_name(ea),
                "depth": graph.get(ea, {}).get("depth", 0),
                "incoming": [
                    {"ea": f"0x{x:X}", "name": function_name(x)}
                    for x in graph.get(ea, {}).get("incoming", [])
                ],
                "outgoing": [
                    {"ea": f"0x{x:X}", "name": function_name(x)}
                    for x in graph.get(ea, {}).get("outgoing", [])
                ],
            }
            for ea in sorted(targets)
        ],
        "decompile": entries,
    }

    with open(os.path.join(OUTPUT_DIR, "_TARGET_GRAPH.json"), "w") as f:
        json.dump(graph_json, f, indent=2)

    with open(os.path.join(OUTPUT_DIR, "_TARGET_STRINGS.txt"), "w") as f:
        for hit in string_hits:
            f.write(f"0x{hit['ea']:X}\t{hit['text']}\n")

    with open(os.path.join(OUTPUT_DIR, "_FUNCTIONS.txt"), "w") as f:
        for ea in sorted(targets):
            f.write(f"0x{ea:X}\t{function_name(ea)}\n")

    summary = f"{ok_count}/{len(entries)} targeted functions decompiled, {fail_count} failed, {elapsed:.0f}s"
    with open(os.path.join(OUTPUT_DIR, "_DONE.txt"), "w") as f:
        f.write(summary + "\n")
    print(f"[*] Done: {summary}")


main()
