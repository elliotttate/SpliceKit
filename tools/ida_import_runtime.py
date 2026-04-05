"""
ida_import_runtime.py — IDAPython script to enrich IDA decompilation with live ObjC runtime data.

Load this script inside IDA Pro (File > Script file, or Alt+F7) after exporting
runtime metadata with fcp_runtime_export.py.

Import pipeline:
    Phase 1: Create struct types from class ivars with typed members
    Phase 2: Register types in local type library (til)
    Phase 3: Rename functions to ObjC names and set prototypes
    Phase 4: Resolve objc_msgSend cross-references
    Phase 5: Add class hierarchy and protocol comments
    Phase 6: Create enums for known constants
    Phase 7: Organize functions into class folders
    Phase 8: Trigger type propagation

Usage in IDA:
    1. Export metadata:  python3 fcp_runtime_export.py --binary Flexo -o ida_export
    2. Open the matching binary in IDA Pro
    3. Run this script: File > Script file > ida_import_runtime.py
    4. Select the JSON file when prompted (e.g., ida_export/Flexo.json)

Requires: IDA Pro 7.0+ with IDAPython (Python 3)
"""

import json
import os
import sys

# Add the tools directory to path so we can import the type parser
SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
if SCRIPT_DIR not in sys.path:
    sys.path.insert(0, SCRIPT_DIR)

from ida_objc_types import ObjCTypeParser, build_class_struct, KNOWN_STRUCTS


# ---- IDA API imports (only available inside IDA) ----

def _check_ida():
    try:
        import idaapi
        return True
    except ImportError:
        return False

IDA_AVAILABLE = _check_ida()

if IDA_AVAILABLE:
    import idaapi
    import idautils
    import idc
    import ida_name
    import ida_struct
    import ida_typeinf
    import ida_bytes
    import ida_funcs
    import ida_nalt
    import ida_enum
    import ida_xref
    import ida_auto
    try:
        import ida_dirtree
        HAS_DIRTREE = True
    except ImportError:
        HAS_DIRTREE = False  # IDA < 7.7
    try:
        import ida_hexrays
        HAS_HEXRAYS = True
    except ImportError:
        HAS_HEXRAYS = False


# Known struct sizes for ivar typing (arm64)
STRUCT_SIZES = {
    "CGPoint": 16, "CGSize": 16, "CGRect": 32,
    "CGAffineTransform": 48, "NSRange": 16, "_NSRange": 16,
    "CMTime": 24, "CMTimeRange": 48, "CMTimeMapping": 96,
}


def _size_for_parsed_type(parsed) -> int:
    """Determine byte size for a parsed type on arm64."""
    if parsed.c_type in ("BOOL", "char", "unsigned char"):
        return 1
    elif parsed.c_type in ("short", "unsigned short"):
        return 2
    elif parsed.c_type in ("int", "unsigned int", "int32_t", "uint32_t", "float"):
        return 4
    elif parsed.c_type in ("double", "long long", "unsigned long long"):
        return 8
    elif parsed.is_pointer or parsed.c_type in ("id", "Class", "SEL",
                                                  "id /* block */", "char *", "void *"):
        return 8
    elif parsed.is_struct:
        return STRUCT_SIZES.get(parsed.struct_name, 8)
    return 8


def _flag_for_size(size: int):
    """Return IDA data flag for a given byte size."""
    if size == 1:
        return ida_bytes.FF_BYTE
    elif size == 2:
        return ida_bytes.FF_WORD
    elif size == 4:
        return ida_bytes.FF_DWORD
    else:
        return ida_bytes.FF_QWORD


class IDAImporter:
    """Imports runtime metadata into an IDA database."""

    def __init__(self, json_path: str, image_map_path: str = None):
        with open(json_path) as f:
            self.data = json.load(f)

        self.classes = self.data.get("classes", [])
        self.image_info = self.data.get("image", {})
        self.binary_name = self.data.get("binary", "")

        # Load image map for ASLR slide
        if image_map_path is None:
            image_map_path = os.path.join(os.path.dirname(json_path), "_image_map.json")

        self.slide = 0
        self.runtime_base = 0
        if os.path.exists(image_map_path):
            with open(image_map_path) as f:
                image_map = json.load(f)
            if self.binary_name in image_map:
                info = image_map[self.binary_name]
                self.slide = int(info.get("slide", "0x0"), 16)
                self.runtime_base = int(info.get("baseAddress", "0x0"), 16)
        elif self.image_info:
            self.slide = int(self.image_info.get("slide", "0x0"), 16)
            self.runtime_base = int(self.image_info.get("baseAddress", "0x0"), 16)

        self.parser = ObjCTypeParser()

        # Build selector -> [(class_name, ida_addr, is_class_method, type_enc)] lookup
        self.selector_map: dict[str, list] = {}

        # Stats
        self.stats = {
            "functions_renamed": 0,
            "prototypes_set": 0,
            "structs_created": 0,
            "member_types_set": 0,
            "til_types_added": 0,
            "comments_added": 0,
            "xrefs_added": 0,
            "folders_created": 0,
            "errors": 0,
        }

    def runtime_to_ida(self, runtime_addr: int) -> int:
        """Convert a runtime IMP address to an IDA database address."""
        if self.slide == 0:
            return runtime_addr
        return runtime_addr - self.slide

    def import_all(self, dry_run: bool = False):
        """Run the full import pipeline."""
        print(f"Importing {len(self.classes)} classes from {self.binary_name}")
        print(f"ASLR slide: 0x{self.slide:X}")
        print(f"Runtime base: 0x{self.runtime_base:X}")
        if IDA_AVAILABLE:
            ida_base = idaapi.get_imagebase()
            print(f"IDA image base: 0x{ida_base:X}")
        print()

        # Build the selector map first (needed for xref resolution)
        self._build_selector_map()

        print("=== Phase 1: Creating struct types from ivars ===")
        self._create_structs(dry_run)

        print("\n=== Phase 2: Registering types in local type library ===")
        self._register_til_types(dry_run)

        print("\n=== Phase 3: Renaming functions and setting prototypes ===")
        self._rename_and_type_functions(dry_run)

        print("\n=== Phase 4: Resolving objc_msgSend cross-references ===")
        self._resolve_msgsend_xrefs(dry_run)

        print("\n=== Phase 5: Adding class hierarchy comments ===")
        self._add_class_comments(dry_run)

        print("\n=== Phase 6: Creating enums ===")
        self._create_enums(dry_run)

        print("\n=== Phase 7: Organizing functions into class folders ===")
        self._organize_function_folders(dry_run)

        print("\n=== Phase 8: Triggering type propagation ===")
        self._trigger_type_propagation(dry_run)

        print("\n=== Import Summary ===")
        for k, v in self.stats.items():
            print(f"  {k}: {v}")

    def _build_selector_map(self):
        """Build selector -> implementations lookup for xref resolution."""
        for cls in self.classes:
            if isinstance(cls, str):
                continue
            class_name = cls["name"]
            for method in cls.get("instanceMethods", []):
                sel = method.get("selector", "")
                imp = int(method.get("imp", "0x0"), 16)
                if sel and imp:
                    self.selector_map.setdefault(sel, []).append(
                        (class_name, self.runtime_to_ida(imp), False, method.get("typeEncoding", "")))
            for method in cls.get("classMethods", []):
                sel = method.get("selector", "")
                imp = int(method.get("imp", "0x0"), 16)
                if sel and imp:
                    self.selector_map.setdefault(sel, []).append(
                        (class_name, self.runtime_to_ida(imp), True, method.get("typeEncoding", "")))

        print(f"  Built selector map: {len(self.selector_map)} unique selectors, "
              f"{sum(len(v) for v in self.selector_map.values())} implementations")

    def _create_structs(self, dry_run: bool):
        """Create IDA struct types from class ivar metadata with typed members."""
        for cls in self.classes:
            if isinstance(cls, str):
                continue
            if not cls.get("ivars"):
                continue

            class_name = cls["name"]
            if dry_run:
                print(f"  Would create struct: {class_name} ({len(cls['ivars'])} fields)")
                continue

            if not IDA_AVAILABLE:
                continue

            # Delete existing struct
            sid = ida_struct.get_struc_id(class_name)
            if sid != idaapi.BADADDR:
                ida_struct.del_struc(ida_struct.get_struc(sid))

            sid = ida_struct.add_struc(idaapi.BADADDR, class_name, 0)
            if sid == idaapi.BADADDR:
                self.stats["errors"] += 1
                continue

            sptr = ida_struct.get_struc(sid)

            # Get ivar layout info for strong/weak annotation
            ivar_layout = cls.get("ivarLayout", {})
            strong_indices = set(ivar_layout.get("strong", []))
            weak_indices = set(ivar_layout.get("weak", []))

            for ivar in cls["ivars"]:
                offset = ivar.get("offset", -1)
                if offset < 0:
                    continue

                name = ivar["name"]
                type_enc = ivar.get("type", "?")
                parsed = self.parser.parse(type_enc)
                size = _size_for_parsed_type(parsed)
                flag = _flag_for_size(size)

                err = ida_struct.add_struc_member(sptr, name, offset, flag, None, size)
                if err != 0:
                    continue

                # Set typed member info (the key improvement for pseudocode)
                member = ida_struct.get_member_by_name(sptr, name)
                if member:
                    tinfo = ida_typeinf.tinfo_t()
                    c_decl = parsed.c_type
                    # Add strong/weak annotation as comment
                    ptr_index = offset // 8  # pointer-sized slots
                    if ptr_index in weak_indices:
                        c_decl = f"__weak {c_decl}"

                    if ida_typeinf.parse_decl(tinfo, None, f"{c_decl} x;", ida_typeinf.PT_SIL):
                        if ida_struct.set_member_tinfo(sptr, member, 0, tinfo,
                                                        ida_struct.SET_MEMTI_MAY_DESTROY):
                            self.stats["member_types_set"] += 1

            self.stats["structs_created"] += 1

    def _register_til_types(self, dry_run: bool):
        """Register struct definitions in IDA's local type library for persistence."""
        if dry_run:
            struct_count = sum(1 for cls in self.classes
                             if not isinstance(cls, str) and cls.get("ivars"))
            print(f"  Would register {struct_count} types in local til")
            return

        if not IDA_AVAILABLE:
            return

        til = ida_typeinf.get_idati()
        registered = 0

        for cls in self.classes:
            if isinstance(cls, str):
                continue
            if not cls.get("ivars"):
                continue

            class_name = cls["name"]
            struct_def = build_class_struct(cls, self.parser)
            if not struct_def:
                continue

            tinfo = ida_typeinf.tinfo_t()
            if ida_typeinf.parse_decl(tinfo, til, struct_def + ";", ida_typeinf.PT_SIL):
                # Save to local types
                tinfo.set_named_type(til, class_name, ida_typeinf.NTF_REPLACE)
                registered += 1

        # Also register discovered structs from type encoding parsing
        for name, definition in self.parser.get_struct_definitions().items():
            if name in KNOWN_STRUCTS:
                continue
            tinfo = ida_typeinf.tinfo_t()
            if ida_typeinf.parse_decl(tinfo, til, definition + ";", ida_typeinf.PT_SIL):
                tinfo.set_named_type(til, name, ida_typeinf.NTF_REPLACE)
                registered += 1

        self.stats["til_types_added"] = registered
        print(f"  Registered {registered} types in local til")

    def _rename_and_type_functions(self, dry_run: bool):
        """Rename functions to ObjC names and set type signatures."""
        for cls in self.classes:
            if isinstance(cls, str):
                continue
            class_name = cls["name"]

            for method in cls.get("instanceMethods", []):
                self._process_method(class_name, method, False, dry_run)
            for method in cls.get("classMethods", []):
                self._process_method(class_name, method, True, dry_run)

    def _process_method(self, class_name: str, method: dict,
                        is_class_method: bool, dry_run: bool):
        """Process a single method: rename function and set prototype."""
        selector = method.get("selector", "")
        imp_str = method.get("imp", "0x0")
        type_enc = method.get("typeEncoding", "")
        image = method.get("image", "")  # from dladdr — which binary owns the IMP

        runtime_addr = int(imp_str, 16)
        if runtime_addr == 0:
            return

        ida_addr = self.runtime_to_ida(runtime_addr)
        prefix = "+" if is_class_method else "-"
        objc_name = f"{prefix}[{class_name} {selector}]"

        if dry_run:
            suffix = f" (from {image})" if image else ""
            if type_enc:
                proto = self.parser.method_to_ida_prototype(
                    type_enc, class_name, selector, is_class_method)
                print(f"  0x{ida_addr:X}: {objc_name}  ->  {proto}{suffix}")
            else:
                print(f"  0x{ida_addr:X}: {objc_name}{suffix}")
            return

        if not IDA_AVAILABLE:
            return

        # Rename
        if ida_name.set_name(ida_addr, objc_name, ida_name.SN_NOWARN | ida_name.SN_FORCE):
            self.stats["functions_renamed"] += 1
        else:
            safe_name = (f"{'_OBJC_CLASS_' if is_class_method else '_OBJC_INST_'}"
                        f"{class_name}_{selector.replace(':', '_')}")
            if ida_name.set_name(ida_addr, safe_name, ida_name.SN_NOWARN):
                self.stats["functions_renamed"] += 1

        # Set prototype
        if type_enc:
            try:
                proto = self.parser.method_to_ida_prototype(
                    type_enc, class_name, selector, is_class_method)
                tinfo = ida_typeinf.tinfo_t()
                if ida_typeinf.parse_decl(tinfo, None, proto + ";", ida_typeinf.PT_SIL):
                    if ida_typeinf.apply_tinfo(ida_addr, tinfo, ida_typeinf.TINFO_DEFINITE):
                        self.stats["prototypes_set"] += 1
            except Exception:
                self.stats["errors"] += 1

        # Add category annotation if IMP lives in a different image
        if image and image != self.binary_name:
            existing_cmt = idc.get_func_cmt(ida_addr, 1) or ""
            cat_note = f"Category from: {image}"
            if cat_note not in existing_cmt:
                idc.set_func_cmt(ida_addr, f"{existing_cmt}\n{cat_note}".strip(), 1)

    def _resolve_msgsend_xrefs(self, dry_run: bool):
        """Resolve objc_msgSend call sites to actual implementations.

        For each call to objc_msgSend, read the selector argument and look up
        which class(es) implement it. Add cross-references and comments.
        """
        if not IDA_AVAILABLE and not dry_run:
            return

        if dry_run:
            print(f"  Would scan for objc_msgSend call sites and resolve "
                  f"{len(self.selector_map)} known selectors")
            # Show some example resolutions
            example_count = 0
            for sel, impls in sorted(self.selector_map.items()):
                if len(impls) == 1:
                    cls_name, addr, is_cm, _ = impls[0]
                    prefix = "+" if is_cm else "-"
                    print(f"    {sel} -> {prefix}[{cls_name} {sel}] @ 0x{addr:X}")
                    example_count += 1
                    if example_count >= 10:
                        remaining = sum(1 for v in self.selector_map.values() if len(v) == 1)
                        print(f"    ... and {remaining - 10} more unambiguous selectors")
                        break
            ambiguous = sum(1 for v in self.selector_map.values() if len(v) > 1)
            print(f"    {ambiguous} selectors have multiple implementations (comment-annotated)")
            return

        # Find objc_msgSend address(es)
        msgsend_addrs = []
        for name in ["_objc_msgSend", "objc_msgSend"]:
            ea = ida_name.get_name_ea(idaapi.BADADDR, name)
            if ea != idaapi.BADADDR:
                msgsend_addrs.append(ea)

        if not msgsend_addrs:
            print("  objc_msgSend not found in binary")
            return

        xrefs_added = 0
        comments_added = 0

        for msgsend_ea in msgsend_addrs:
            # Iterate all call sites to this objc_msgSend
            for xref in idautils.CodeRefsTo(msgsend_ea, 0):
                # Try to read the selector string from the call site
                # On arm64: x1 is loaded with a selector ref before the BL
                # We look backward for an ADRP+LDR or ADR loading into x1
                sel_str = self._read_selector_at_callsite(xref)
                if not sel_str:
                    continue

                impls = self.selector_map.get(sel_str)
                if not impls:
                    continue

                if len(impls) == 1:
                    # Unambiguous: add direct cross-reference
                    cls_name, impl_addr, is_cm, type_enc = impls[0]
                    prefix = "+" if is_cm else "-"
                    ida_xref.add_cref(xref, impl_addr, ida_xref.fl_CN)
                    # Add inline comment
                    idc.set_cmt(xref, f"-> {prefix}[{cls_name} {sel_str}]", 0)
                    xrefs_added += 1
                else:
                    # Ambiguous: add comment listing candidates
                    candidates = []
                    for cls_name, impl_addr, is_cm, _ in impls[:5]:
                        prefix = "+" if is_cm else "-"
                        candidates.append(f"{prefix}[{cls_name} {sel_str}]")
                    if len(impls) > 5:
                        candidates.append(f"... +{len(impls) - 5} more")
                    idc.set_cmt(xref, f"-> {' | '.join(candidates)}", 0)
                    comments_added += 1

        self.stats["xrefs_added"] = xrefs_added
        self.stats["comments_added"] += comments_added
        print(f"  Added {xrefs_added} direct xrefs, {comments_added} disambiguation comments")

    def _read_selector_at_callsite(self, call_ea: int) -> str | None:
        """Try to read the selector string loaded into x1 at a call site.

        Looks backward from the call instruction for the selector reference.
        This handles common arm64 patterns:
          ADRP x1, selref@PAGE
          LDR  x1, [x1, selref@PAGEOFF]
          BL   _objc_msgSend
        """
        if not IDA_AVAILABLE:
            return None

        # Walk backward up to 10 instructions looking for x1 setup
        ea = call_ea
        for _ in range(10):
            ea = idc.prev_head(ea)
            if ea == idaapi.BADADDR:
                break

            # Check if this instruction writes to x1
            mnem = idc.print_insn_mnem(ea)
            if not mnem:
                continue

            # LDR x1, [addr] — the addr points to a selref which contains a pointer to the name
            if mnem in ("LDR", "ADRP"):
                # Try to get the operand value — IDA resolves selector refs
                for op_idx in range(3):
                    op_val = idc.get_operand_value(ea, op_idx)
                    if op_val and op_val != idaapi.BADADDR:
                        # Try to read the string at this address or pointed-to address
                        name = ida_name.get_name(op_val)
                        if name and name.startswith("sel_"):
                            return name[4:]  # strip "sel_" prefix
                        # Try reading the selector name from the referred data
                        ref_str = idc.get_strlit_contents(op_val)
                        if ref_str:
                            return ref_str.decode("utf-8") if isinstance(ref_str, bytes) else ref_str

            # Direct reference with selector name in operand
            disasm = idc.GetDisasm(ea)
            if disasm and "selRef_" in disasm:
                # Extract selector name from "selRef_selectorName"
                idx = disasm.index("selRef_")
                sel_part = disasm[idx + 7:].split()[0].split(",")[0].split("]")[0]
                if sel_part:
                    return sel_part.replace("_", ":")  # rough heuristic

        return None

    def _add_class_comments(self, dry_run: bool):
        """Add comments with class hierarchy, protocols, and category info."""
        for cls in self.classes:
            if isinstance(cls, str):
                continue
            class_name = cls["name"]
            superchain = cls.get("superchain", [])
            protocols = cls.get("protocols", [])

            if not superchain and not protocols:
                continue

            # Build comment — protocols now have method details
            lines = [f"Class: {class_name}"]
            if superchain:
                lines.append(f"Inherits: {' -> '.join(superchain)}")

            for proto in protocols:
                if isinstance(proto, dict):
                    proto_name = proto.get("name", "?")
                    req_methods = proto.get("requiredInstanceMethods", [])
                    opt_methods = proto.get("optionalInstanceMethods", [])
                    inherits = proto.get("inheritsFrom", [])
                    line = f"Protocol: {proto_name}"
                    if inherits:
                        line += f" (inherits: {', '.join(inherits)})"
                    if req_methods:
                        line += f" — required: {', '.join(m['selector'] for m in req_methods[:5])}"
                        if len(req_methods) > 5:
                            line += f" +{len(req_methods) - 5} more"
                    lines.append(line)
                else:
                    lines.append(f"Protocol: {proto}")

            comment = "\n".join(lines)

            # Find the first method to attach the comment to
            first_imp = None
            for method in cls.get("instanceMethods", []) + cls.get("classMethods", []):
                addr = int(method.get("imp", "0x0"), 16)
                if addr > 0 and (first_imp is None or addr < first_imp):
                    first_imp = addr

            if first_imp is None:
                continue

            ida_addr = self.runtime_to_ida(first_imp)

            if dry_run:
                chain_str = " -> ".join([class_name] + superchain)
                proto_names = []
                for p in protocols:
                    proto_names.append(p["name"] if isinstance(p, dict) else p)
                print(f"  {class_name} @ 0x{ida_addr:X}: {chain_str}")
                if proto_names:
                    print(f"    Protocols: {', '.join(proto_names)}")
                continue

            if not IDA_AVAILABLE:
                continue

            idc.set_func_cmt(ida_addr, comment, 0)
            self.stats["comments_added"] += 1

    def _create_enums(self, dry_run: bool):
        """Create enums for known FCP constant sets."""
        enums = {
            "ProAppSupportLogLevel": {
                "LOG_TRACE": 0,
                "LOG_DEBUG": 1,
                "LOG_INFO": 2,
                "LOG_WARNING": 3,
                "LOG_ERROR": 4,
                "LOG_FAILURE": 5,
            },
            "TLKDebugOption": {
                "TLK_ShowItemLaneIndex": 0,
                "TLK_ShowMisalignedEdges": 1,
                "TLK_ShowRenderBar": 2,
                "TLK_ShowHiddenGapItems": 3,
                "TLK_ShowHiddenItemHeaders": 4,
                "TLK_ShowInvalidLayoutRects": 5,
                "TLK_ShowContainerBounds": 6,
                "TLK_ShowContentLayers": 7,
                "TLK_ShowRulerBounds": 8,
                "TLK_ShowUsedRegion": 9,
                "TLK_ShowZeroHeightSpineItems": 10,
                "TLK_PerformanceMonitorEnabled": 11,
            },
        }

        for name, members in enums.items():
            if dry_run:
                print(f"  Would create enum: {name} ({len(members)} members)")
                continue

            if not IDA_AVAILABLE:
                continue

            eid = ida_enum.get_enum(name)
            if eid != idaapi.BADADDR:
                continue

            eid = ida_enum.add_enum(idaapi.BADADDR, name, 0)
            if eid == idaapi.BADADDR:
                self.stats["errors"] += 1
                continue

            for member_name, value in members.items():
                ida_enum.add_enum_member(eid, member_name, value)

    def _organize_function_folders(self, dry_run: bool):
        """Organize renamed functions into class-based folders (IDA 7.7+)."""
        if not IDA_AVAILABLE or not HAS_DIRTREE:
            if dry_run:
                class_count = sum(1 for cls in self.classes
                                 if not isinstance(cls, str)
                                 and (cls.get("instanceMethods") or cls.get("classMethods")))
                print(f"  Would create {class_count} class folders")
            return

        if dry_run:
            return

        try:
            dt = ida_dirtree.get_std_dirtree(ida_dirtree.DIRTREE_FUNCS)
            if not dt:
                return

            # Create ObjC root folder
            dt.mkdir("ObjC")
            folders_created = 0

            for cls in self.classes:
                if isinstance(cls, str):
                    continue
                class_name = cls["name"]
                all_methods = cls.get("instanceMethods", []) + cls.get("classMethods", [])
                if not all_methods:
                    continue

                folder_path = f"ObjC/{class_name}"
                dt.mkdir(folder_path)

                for method in all_methods:
                    imp = int(method.get("imp", "0x0"), 16)
                    if imp == 0:
                        continue
                    ida_addr = self.runtime_to_ida(imp)
                    func_name = ida_name.get_name(ida_addr)
                    if func_name:
                        try:
                            dt.rename(func_name, f"{folder_path}/{func_name}")
                        except Exception:
                            pass

                folders_created += 1

            self.stats["folders_created"] = folders_created
            print(f"  Created {folders_created} class folders")
        except Exception as e:
            print(f"  Folder organization skipped: {e}")

    def _trigger_type_propagation(self, dry_run: bool):
        """Trigger IDA's type propagation after all types are set."""
        if dry_run:
            print("  Would trigger ida_auto.auto_wait() for type propagation")
            return

        if not IDA_AVAILABLE:
            return

        print("  Running type propagation (auto_wait)...")
        ida_auto.auto_wait()
        print("  Type propagation complete")

        # Optionally refresh hex-rays decompiler cache
        if HAS_HEXRAYS:
            try:
                ida_hexrays.init_hexrays_plugin()
                print("  Hex-Rays decompiler cache refreshed")
            except Exception:
                pass

    def dump_stats_json(self, path: str):
        """Write import stats to a JSON file."""
        with open(path, "w") as f:
            json.dump(self.stats, f, indent=2)


def generate_header(json_path: str, output_path: str):
    """Generate a C header file from runtime metadata (for use outside IDA too)."""
    with open(json_path) as f:
        data = json.load(f)

    classes = data.get("classes", [])
    binary_name = data.get("binary", "unknown")
    parser = ObjCTypeParser()

    lines = [
        f"/* Auto-generated from SpliceKit runtime export: {binary_name} */",
        f"/* {len(classes)} classes */",
        "",
        "#pragma once",
        "#include <objc/objc.h>",
        "#include <CoreMedia/CoreMedia.h>",
        "#include <CoreGraphics/CoreGraphics.h>",
        "",
    ]

    # Forward declarations
    for cls in classes:
        if isinstance(cls, str):
            lines.append(f"@class {cls};")
        else:
            lines.append(f"@class {cls['name']};")
    lines.append("")

    # Struct definitions
    for cls in classes:
        if isinstance(cls, str):
            continue
        struct_def = build_class_struct(cls, parser)
        if struct_def:
            lines.append(struct_def)
            lines.append("")

    # Discovered struct definitions from type parsing
    for name, definition in parser.get_struct_definitions().items():
        if name not in KNOWN_STRUCTS:
            lines.append(definition)
            lines.append("")

    with open(output_path, "w") as f:
        f.write("\n".join(lines))
    print(f"Generated header: {output_path}")


# ---- Entry point ----

def main():
    """Entry point when run inside IDA or from command line."""
    if IDA_AVAILABLE:
        json_path = idaapi.ask_file(0, "*.json", "Select runtime export JSON")
        if not json_path:
            print("Cancelled.")
            return

        importer = IDAImporter(json_path)
        importer.import_all(dry_run=False)
        print("\nDone! Refresh the decompiler view (F5) to see improved pseudocode.")
    else:
        import argparse
        ap = argparse.ArgumentParser(description="IDA Pro runtime metadata importer (dry-run outside IDA)")
        ap.add_argument("json_file", help="Path to per-binary JSON export")
        ap.add_argument("--dry-run", action="store_true", default=True,
                        help="Print what would be done (default outside IDA)")
        ap.add_argument("--header", help="Generate C header file instead of IDA import")
        ap.add_argument("--max-classes", type=int, default=0,
                        help="Limit number of classes to process (0=all)")
        args = ap.parse_args()

        if args.header:
            generate_header(args.json_file, args.header)
            return

        importer = IDAImporter(args.json_file)
        if args.max_classes > 0:
            importer.classes = importer.classes[:args.max_classes]
        importer.import_all(dry_run=True)


if __name__ == "__main__":
    main()
