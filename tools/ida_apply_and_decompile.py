"""
ida_apply_and_decompile.py — IDAPython headless script for IDA 9.x.

Applies runtime metadata from SpliceKit export JSON, then decompiles all functions.
Run via: idat -A -o"db.i64" -S"ida_apply_and_decompile.py" /path/to/binary

Environment variables:
    RUNTIME_JSON          — Path to per-binary JSON from fcp_runtime_export.py
    IMAGE_MAP_JSON        — Path to _image_map.json (auto-detected)
    DECOMPILE_OUTPUT_DIR  — Directory to write .c files to
"""
import os
import sys
import json
import time

import idaapi
import idautils
import idc
import ida_auto
import ida_bytes
import ida_funcs
import ida_hexrays
import ida_loader
import ida_name
import ida_typeinf
import ida_xref

# Add tools dir to path for type parser
SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
if SCRIPT_DIR not in sys.path:
    sys.path.insert(0, SCRIPT_DIR)

from ida_objc_types import ObjCTypeParser, build_class_struct, IDA_TYPE_MAP

RUNTIME_JSON = os.environ.get("RUNTIME_JSON", "")
IMAGE_MAP_JSON = os.environ.get("IMAGE_MAP_JSON", "")
OUTPUT_DIR = os.environ.get("DECOMPILE_OUTPUT_DIR", "/tmp/decompiled")


def sanitize_filename(name):
    for ch in '/\\:*?"<>|':
        name = name.replace(ch, "_")
    return name[:200]


def apply_runtime_metadata():
    """Apply runtime metadata to the IDB."""
    if not RUNTIME_JSON or not os.path.exists(RUNTIME_JSON):
        print(f"[!] RUNTIME_JSON not set or not found: {RUNTIME_JSON}")
        return 0

    print(f"[*] Loading runtime metadata from {RUNTIME_JSON}")
    with open(RUNTIME_JSON) as f:
        data = json.load(f)

    classes = data.get("classes", [])
    binary_name = data.get("binary", "")

    # Load ASLR slide
    slide = 0
    map_path = IMAGE_MAP_JSON if IMAGE_MAP_JSON and os.path.exists(IMAGE_MAP_JSON) \
        else os.path.join(os.path.dirname(RUNTIME_JSON), "_image_map.json")

    if os.path.exists(map_path):
        with open(map_path) as f:
            image_map = json.load(f)
        if binary_name in image_map:
            slide = int(image_map[binary_name].get("slide", "0x0"), 16)

    ida_base = idaapi.get_imagebase()
    print(f"[*] Binary: {binary_name}, ASLR slide: 0x{slide:X}, IDA base: 0x{ida_base:X}")
    print(f"[*] Classes: {len(classes)}")

    parser = ObjCTypeParser()
    stats = {"renamed": 0, "typed": 0, "structs": 0, "comments": 0, "errors": 0}

    # --- Phase 1: Declare struct types via C declarations ---
    print("[*] Phase 1: Declaring struct types...")
    til = ida_typeinf.get_idati()

    for cls in classes:
        if isinstance(cls, str) or not cls.get("ivars"):
            continue
        struct_def = build_class_struct(cls, parser)
        if not struct_def:
            continue

        tinfo = ida_typeinf.tinfo_t()
        if ida_typeinf.parse_decl(tinfo, til, struct_def + ";", ida_typeinf.PT_SIL):
            tinfo.set_named_type(til, cls["name"], ida_typeinf.NTF_REPLACE)
            stats["structs"] += 1

    print(f"    Declared {stats['structs']} struct types")

    # --- Phase 2: Rename functions and set prototypes ---
    print("[*] Phase 2: Renaming functions and setting prototypes...")
    for cls in classes:
        if isinstance(cls, str):
            continue
        class_name = cls["name"]

        for is_class_method, methods in [(False, cls.get("instanceMethods", [])),
                                          (True, cls.get("classMethods", []))]:
            for method in methods:
                selector = method.get("selector", "")
                imp_str = method.get("imp", "0x0")
                type_enc = method.get("typeEncoding", "")

                runtime_addr = int(imp_str, 16)
                if runtime_addr == 0:
                    continue

                ida_addr = runtime_addr - slide if slide else runtime_addr
                prefix = "+" if is_class_method else "-"
                objc_name = f"{prefix}[{class_name} {selector}]"

                # Rename
                if ida_name.set_name(ida_addr, objc_name,
                                      ida_name.SN_NOWARN | ida_name.SN_FORCE):
                    stats["renamed"] += 1
                else:
                    safe = (f"{'_OBJC_CLASS_' if is_class_method else '_OBJC_INST_'}"
                            f"{class_name}_{selector.replace(':', '_')}")
                    if ida_name.set_name(ida_addr, safe, ida_name.SN_NOWARN):
                        stats["renamed"] += 1

                # Set function prototype
                # Use IDA-safe C types and a dummy name for parse_decl
                if type_enc:
                    try:
                        ret_type, params = parser.parse_method_encoding(type_enc)
                        ret_c = IDA_TYPE_MAP.get(ret_type.c_type, ret_type.c_type)
                        # Build param list with IDA-safe types
                        param_strs = []
                        for pi, p in enumerate(params):
                            if pi == 0:
                                # self — use the class struct if we declared it, else void*
                                param_strs.append(f"void * self")
                            elif pi == 1:
                                param_strs.append("char * _cmd")  # SEL
                            else:
                                pc = IDA_TYPE_MAP.get(p.c_type, p.c_type)
                                param_strs.append(f"{pc} arg{pi - 2}")
                        safe_name = f"_fcpb_{ida_addr:X}"
                        decl = f"{ret_c} __cdecl {safe_name}({', '.join(param_strs)});"
                        tinfo = ida_typeinf.tinfo_t()
                        if ida_typeinf.parse_decl(tinfo, None, decl, ida_typeinf.PT_SIL):
                            if ida_typeinf.apply_tinfo(ida_addr, tinfo, ida_typeinf.TINFO_DEFINITE):
                                stats["typed"] += 1
                        elif stats["errors"] < 5:
                            print(f"    [!] parse_decl failed: {decl[:100]}")
                    except Exception as e:
                        stats["errors"] += 1
                        if stats["errors"] <= 5:
                            print(f"    [!] Exception: {e}")

    print(f"    Renamed {stats['renamed']}, typed {stats['typed']}, errors {stats['errors']}")

    # --- Phase 3: Add class hierarchy comments ---
    print("[*] Phase 3: Adding class comments...")
    for cls in classes:
        if isinstance(cls, str):
            continue
        class_name = cls["name"]
        superchain = cls.get("superchain", [])
        protocols = cls.get("protocols", [])
        if not superchain and not protocols:
            continue

        lines = [f"Class: {class_name}"]
        if superchain:
            lines.append(f"Inherits: {' -> '.join(superchain)}")
        for p in protocols:
            pname = p.get("name", p) if isinstance(p, dict) else p
            lines.append(f"Protocol: {pname}")

        # Find lowest method address
        first_imp = None
        for m in cls.get("instanceMethods", []) + cls.get("classMethods", []):
            addr = int(m.get("imp", "0x0"), 16)
            if addr > 0 and (first_imp is None or addr < first_imp):
                first_imp = addr

        if first_imp:
            ida_addr = first_imp - slide if slide else first_imp
            idc.set_func_cmt(ida_addr, "\n".join(lines), 0)
            stats["comments"] += 1

    print(f"    Added {stats['comments']} comments")

    # Type propagation
    print("[*] Phase 4: Running type propagation...")
    ida_auto.auto_wait()

    print(f"[*] Metadata applied: {json.dumps(stats)}")
    return stats["renamed"]


def decompile_all():
    """Decompile all functions and write .c files."""
    os.makedirs(OUTPUT_DIR, exist_ok=True)

    if not ida_hexrays.init_hexrays_plugin():
        print("[ERROR] Hex-Rays not available!")
        with open(os.path.join(OUTPUT_DIR, "_ERROR.txt"), "w") as f:
            f.write("Hex-Rays decompiler not available\n")
        return

    total = sum(1 for _ in idautils.Functions())
    print(f"[*] Decompiling {total} functions -> {OUTPUT_DIR}")

    start = time.time()
    success = 0
    failed = 0
    failed_list = []
    index_lines = []

    for i, ea in enumerate(idautils.Functions()):
        fname = ida_name.get_ea_name(ea) or f"sub_{ea:X}"
        safe = sanitize_filename(fname)

        try:
            cfunc = ida_hexrays.decompile(ea)
            if cfunc:
                code = str(cfunc)
                out_path = os.path.join(OUTPUT_DIR, f"{safe}.c")
                with open(out_path, "w") as f:
                    f.write(f"// {fname} @ 0x{ea:X}\n")
                    f.write(code)
                    f.write("\n")
                index_lines.append(f"0x{ea:X}\t{fname}\t{safe}.c")
                success += 1
            else:
                failed += 1
                failed_list.append(f"0x{ea:X}\t{fname}\tNone")
        except Exception as ex:
            failed += 1
            failed_list.append(f"0x{ea:X}\t{fname}\t{str(ex)[:100]}")

        if (i + 1) % 5000 == 0:
            elapsed = time.time() - start
            # Write incremental progress to _DONE.txt so we know it's working
            with open(os.path.join(OUTPUT_DIR, "_DONE.txt"), "w") as pf:
                pf.write(f"{success}/{total} in progress, {failed} failed, {elapsed:.0f}s\n")
            print(f"  [{i+1}/{total}] {success} ok, {failed} fail ({elapsed:.0f}s)")

    elapsed = time.time() - start

    with open(os.path.join(OUTPUT_DIR, "_INDEX.txt"), "w") as f:
        f.write("\n".join(index_lines))
    with open(os.path.join(OUTPUT_DIR, "_FAILURES.txt"), "w") as f:
        f.write("\n".join(failed_list))

    summary = f"{success}/{total} decompiled, {failed} failed, {elapsed:.0f}s"
    with open(os.path.join(OUTPUT_DIR, "_DONE.txt"), "w") as f:
        f.write(summary + "\n")
    print(f"[*] Done: {summary}")


def main():
    print("=" * 60)
    print("SpliceKit IDA Import + Decompile (IDA 9.x)")
    print("=" * 60)

    print("[*] Waiting for auto-analysis...")
    ida_auto.auto_wait()
    print("[*] Auto-analysis complete")

    apply_runtime_metadata()
    decompile_all()

    print("[*] Saving IDB...")
    try:
        idc.save_database(idc.get_idb_path(), 0)
    except Exception as e:
        print(f"[!] save_database error (non-fatal): {e}")
    print("[*] All done!")


main()
