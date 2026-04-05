"""
ida_objc_types.py — Parse ObjC type encoding strings into C type declarations.

ObjC runtime type encodings are compact strings like:
    @"NSArray"          -> NSArray *
    {CGRect={CGPoint=dd}{CGSize=dd}} -> struct CGRect
    ^{OpaqueType}       -> struct OpaqueType *
    q                   -> long long
    B                   -> BOOL
    v24@0:8@16          -> void (id self, SEL _cmd, id arg)  [with offsets]

This module parses these into:
    1. C type strings suitable for IDA's SetType()
    2. Struct definitions for IDA's struct creation APIs

Reference: https://developer.apple.com/library/archive/documentation/Cocoa/Conceptual/ObjCRuntimeGuide/Articles/ocrtTypeEncodings.html
"""

from dataclasses import dataclass, field
from typing import Optional


# Primitive type map: encoding char -> (C type, size in bytes on arm64)
PRIMITIVE_TYPES = {
    "c": ("char", 1),
    "i": ("int", 4),
    "s": ("short", 2),
    "l": ("int32_t", 4),        # 'l' is always 32-bit in type encodings
    "q": ("long long", 8),
    "C": ("unsigned char", 1),
    "I": ("unsigned int", 4),
    "S": ("unsigned short", 2),
    "L": ("uint32_t", 4),
    "Q": ("unsigned long long", 8),
    "f": ("float", 4),
    "d": ("double", 8),
    "D": ("long double", 16),
    "B": ("BOOL", 1),
    "v": ("void", 0),
    "*": ("char *", 8),
    "#": ("Class", 8),
    ":": ("SEL", 8),
    "?": ("void *", 8),         # unknown/function pointer
    "@?": ("id /* block */", 8),
}

# IDA-safe type mappings (IDA's C parser doesn't know ObjC types)
IDA_TYPE_MAP = {
    "id": "void *",
    "id /* block */": "void *",
    "Class": "void *",
    "SEL": "char *",
    "BOOL": "unsigned char",
}

# Well-known struct definitions so we don't re-create them
KNOWN_STRUCTS = {
    "CGPoint": "struct CGPoint { double x; double y; };",
    "CGSize": "struct CGSize { double width; double height; };",
    "CGRect": "struct CGRect { struct CGPoint origin; struct CGSize size; };",
    "CGAffineTransform": "struct CGAffineTransform { double a; double b; double c; double d; double tx; double ty; };",
    "NSRange": "struct NSRange { unsigned long long location; unsigned long long length; };",
    "CMTime": "struct CMTime { long long value; int timescale; unsigned int flags; long long epoch; };",
    "CMTimeRange": "struct CMTimeRange { struct CMTime start; struct CMTime duration; };",
    "CMTimeMapping": "struct CMTimeMapping { struct CMTimeRange source; struct CMTimeRange target; };",
    "_NSRange": "struct _NSRange { unsigned long long location; unsigned long long length; };",
}


@dataclass
class ParsedType:
    """Result of parsing a type encoding."""
    c_type: str                          # C type string, e.g. "NSArray *"
    is_pointer: bool = False
    is_struct: bool = False
    struct_name: Optional[str] = None
    struct_fields: list = field(default_factory=list)  # list of (name, ParsedType)
    is_array: bool = False
    array_count: int = 0
    array_element: Optional["ParsedType"] = None
    raw_encoding: str = ""


class ObjCTypeParser:
    """Stateful parser for ObjC type encoding strings."""

    def __init__(self):
        self.discovered_structs: dict[str, str] = {}  # name -> C definition

    def parse(self, encoding: str) -> ParsedType:
        """Parse a complete type encoding string. Returns ParsedType."""
        if not encoding:
            return ParsedType(c_type="void", raw_encoding="")
        pos, result = self._parse_one(encoding, 0)
        result.raw_encoding = encoding
        return result

    def parse_method_encoding(self, encoding: str) -> tuple[ParsedType, list[ParsedType]]:
        """Parse a full method type encoding like 'v24@0:8@16'.

        Returns (return_type, [param_types]).
        The first two params are always (id self, SEL _cmd) — included in the list.
        """
        if not encoding:
            return ParsedType(c_type="void"), []

        pos = 0
        types = []

        while pos < len(encoding):
            # Skip stack frame size numbers
            while pos < len(encoding) and encoding[pos].isdigit():
                pos += 1
            if pos >= len(encoding):
                break

            p, parsed = self._parse_one(encoding, pos)
            types.append(parsed)

            # Skip offset numbers after type
            pos = p
            while pos < len(encoding) and encoding[pos].isdigit():
                pos += 1

        if not types:
            return ParsedType(c_type="void"), []

        return_type = types[0]
        param_types = types[1:] if len(types) > 1 else []
        return return_type, param_types

    def type_to_ida_string(self, parsed: ParsedType) -> str:
        """Convert ParsedType to a string suitable for IDA's SetType()."""
        c = parsed.c_type
        return IDA_TYPE_MAP.get(c, c)

    def to_ida_safe(self, c_type: str) -> str:
        """Convert an ObjC type string to one IDA's C parser will accept."""
        return IDA_TYPE_MAP.get(c_type, c_type)

    def method_to_ida_prototype(self, encoding: str, class_name: str,
                                 selector: str, is_class_method: bool = False) -> str:
        """Convert a method encoding to a full IDA function prototype.

        Example output: "NSArray * -[MyClass myMethod:withArg:](MyClass * self, SEL _cmd, id arg0, int arg1)"
        """
        ret_type, params = self.parse_method_encoding(encoding)

        # Build param list: first is self, second is _cmd, rest are args
        param_strs = []
        for i, p in enumerate(params):
            if i == 0:
                if is_class_method:
                    param_strs.append("Class self")
                else:
                    param_strs.append(f"{class_name} * self")
            elif i == 1:
                param_strs.append("SEL _cmd")
            else:
                param_strs.append(f"{p.c_type} arg{i - 2}")

        prefix = "+" if is_class_method else "-"
        func_name = f"{prefix}[{class_name} {selector}]"
        return f"{ret_type.c_type} __cdecl {func_name}({', '.join(param_strs)})"

    def get_struct_definitions(self) -> dict[str, str]:
        """Return all struct definitions discovered during parsing."""
        return {**KNOWN_STRUCTS, **self.discovered_structs}

    def _parse_one(self, s: str, pos: int) -> tuple[int, ParsedType]:
        """Parse one type at position. Returns (new_pos, ParsedType)."""
        if pos >= len(s):
            return pos, ParsedType(c_type="void")

        ch = s[pos]

        # Pointer to type
        if ch == "^":
            pos += 1
            if pos < len(s) and s[pos] == "{":
                # Pointer to struct
                inner_pos, inner = self._parse_one(s, pos)
                return inner_pos, ParsedType(
                    c_type=f"{inner.c_type} *", is_pointer=True,
                    struct_name=inner.struct_name)
            elif pos < len(s) and s[pos] == "v":
                return pos + 1, ParsedType(c_type="void *", is_pointer=True)
            elif pos < len(s):
                inner_pos, inner = self._parse_one(s, pos)
                return inner_pos, ParsedType(c_type=f"{inner.c_type} *", is_pointer=True)
            return pos, ParsedType(c_type="void *", is_pointer=True)

        # ObjC object: @ or @"ClassName"
        if ch == "@":
            pos += 1
            if pos < len(s) and s[pos] == "?":
                # Block type
                return pos + 1, ParsedType(c_type="id /* block */")
            if pos < len(s) and s[pos] == '"':
                # Quoted class name: @"NSArray"
                end = s.index('"', pos + 1)
                class_name = s[pos + 1:end]
                return end + 1, ParsedType(c_type=f"{class_name} *", is_pointer=True)
            return pos, ParsedType(c_type="id")

        # Struct: {Name=fields} or {Name}
        if ch == "{":
            return self._parse_struct(s, pos)

        # Union: (Name=fields)
        if ch == "(":
            return self._parse_union(s, pos)

        # Array: [countType]
        if ch == "[":
            return self._parse_array(s, pos)

        # Bitfield: bN
        if ch == "b":
            pos += 1
            bits = ""
            while pos < len(s) and s[pos].isdigit():
                bits += s[pos]
                pos += 1
            return pos, ParsedType(c_type=f"unsigned int /* bitfield:{bits} */")

        # const qualifier
        if ch == "r":
            pos += 1
            inner_pos, inner = self._parse_one(s, pos)
            inner.c_type = f"const {inner.c_type}"
            return inner_pos, inner

        # in/out/inout/bycopy/byref/oneway qualifiers
        if ch in "nNoORV":
            pos += 1
            return self._parse_one(s, pos)

        # Check two-char combo for @?
        if ch == "@" and pos + 1 < len(s) and s[pos + 1] == "?":
            return pos + 2, ParsedType(c_type="id /* block */")

        # Primitive type
        if ch in PRIMITIVE_TYPES:
            c_type, _ = PRIMITIVE_TYPES[ch]
            return pos + 1, ParsedType(c_type=c_type)

        # Unknown: treat as int-sized
        return pos + 1, ParsedType(c_type=f"/* unknown:{ch} */ int")

    def _parse_struct(self, s: str, pos: int) -> tuple[int, ParsedType]:
        """Parse {StructName=field1field2...} or {StructName}."""
        assert s[pos] == "{"
        pos += 1

        # Find struct name (up to = or })
        name_start = pos
        depth = 1
        while pos < len(s) and s[pos] not in ("=", "}"):
            if s[pos] == "{":
                depth += 1
            pos += 1

        struct_name = s[name_start:pos]
        if not struct_name or struct_name == "?":
            struct_name = f"anon_struct_{name_start}"

        if pos < len(s) and s[pos] == "}":
            # Opaque struct: {Name}
            return pos + 1, ParsedType(
                c_type=f"struct {struct_name}", is_struct=True,
                struct_name=struct_name)

        # Skip '='
        pos += 1

        # Parse fields
        fields = []
        field_idx = 0
        while pos < len(s) and s[pos] != "}":
            # Check for quoted field name
            field_name = None
            if s[pos] == '"':
                end_quote = s.index('"', pos + 1)
                field_name = s[pos + 1:end_quote]
                pos = end_quote + 1

            if pos < len(s) and s[pos] != "}":
                pos, field_type = self._parse_one(s, pos)
                if not field_name:
                    field_name = f"field_{field_idx}"
                fields.append((field_name, field_type))
                field_idx += 1

        if pos < len(s) and s[pos] == "}":
            pos += 1

        # Generate C struct definition
        if struct_name not in KNOWN_STRUCTS and struct_name not in self.discovered_structs:
            if fields:
                field_strs = [f"    {ft.c_type} {fn};" for fn, ft in fields]
                self.discovered_structs[struct_name] = \
                    f"struct {struct_name} {{\n" + "\n".join(field_strs) + "\n};"

        return pos, ParsedType(
            c_type=f"struct {struct_name}", is_struct=True,
            struct_name=struct_name, struct_fields=fields)

    def _parse_union(self, s: str, pos: int) -> tuple[int, ParsedType]:
        """Parse (UnionName=field1field2...)."""
        assert s[pos] == "("
        pos += 1

        name_start = pos
        while pos < len(s) and s[pos] not in ("=", ")"):
            pos += 1
        union_name = s[name_start:pos]
        if not union_name or union_name == "?":
            union_name = f"anon_union_{name_start}"

        if pos < len(s) and s[pos] == ")":
            return pos + 1, ParsedType(c_type=f"union {union_name}")

        pos += 1  # skip '='
        # Skip fields — just find closing paren
        depth = 1
        while pos < len(s) and depth > 0:
            if s[pos] == "(":
                depth += 1
            elif s[pos] == ")":
                depth -= 1
            pos += 1

        return pos, ParsedType(c_type=f"union {union_name}")

    def _parse_array(self, s: str, pos: int) -> tuple[int, ParsedType]:
        """Parse [countType]."""
        assert s[pos] == "["
        pos += 1

        count_str = ""
        while pos < len(s) and s[pos].isdigit():
            count_str += s[pos]
            pos += 1

        count = int(count_str) if count_str else 0
        pos, elem_type = self._parse_one(s, pos)

        if pos < len(s) and s[pos] == "]":
            pos += 1

        return pos, ParsedType(
            c_type=f"{elem_type.c_type}[{count}]",
            is_array=True, array_count=count, array_element=elem_type)


def build_class_struct(class_info: dict, parser: ObjCTypeParser) -> Optional[str]:
    """Build a C struct definition from class ivar metadata.

    Args:
        class_info: dict with "name", "ivars", "instanceSize"
        parser: ObjCTypeParser instance

    Returns:
        C struct definition string, or None if no ivars
    """
    ivars = class_info.get("ivars", [])
    if not ivars:
        return None

    class_name = class_info["name"]
    lines = [f"struct {class_name} {{"]

    for ivar in ivars:
        name = ivar["name"]
        type_enc = ivar.get("type", "?")
        offset = ivar.get("offset", -1)

        parsed = parser.parse(type_enc)
        c_type = parsed.c_type

        offset_comment = f" /* +0x{offset:X} */" if offset >= 0 else ""
        lines.append(f"    {c_type} {name};{offset_comment}")

    instance_size = class_info.get("instanceSize", 0)
    if instance_size:
        lines.append(f"    /* total size: 0x{instance_size:X} ({instance_size}) */")

    lines.append("};")
    return "\n".join(lines)


# --- Self-test when run directly ---

if __name__ == "__main__":
    parser = ObjCTypeParser()

    test_cases = [
        ("@", "id"),
        ('@"NSArray"', "NSArray *"),
        ('@"NSString"', "NSString *"),
        ("@?", "id /* block */"),
        ("q", "long long"),
        ("Q", "unsigned long long"),
        ("B", "BOOL"),
        ("d", "double"),
        ("f", "float"),
        ("v", "void"),
        ("#", "Class"),
        (":", "SEL"),
        ("*", "char *"),
        ("^v", "void *"),
        ("^@", "id *"),
        ("{CGPoint=dd}", "struct CGPoint"),
        ("{CGRect={CGPoint=dd}{CGSize=dd}}", "struct CGRect"),
        ('{CMTime=qiIq}', "struct CMTime"),
        ("^{OpaqueType}", "struct OpaqueType *"),
        ("[16c]", "char[16]"),
        ("r^{__CFString}", "const struct __CFString *"),
    ]

    print("Type encoding parser tests:")
    all_passed = True
    for enc, expected in test_cases:
        result = parser.parse(enc)
        status = "PASS" if result.c_type == expected else "FAIL"
        if status == "FAIL":
            all_passed = False
            print(f"  {status}: {enc!r} -> {result.c_type!r} (expected {expected!r})")
        else:
            print(f"  {status}: {enc!r} -> {result.c_type!r}")

    # Test method encoding
    print("\nMethod encoding tests:")
    proto = parser.method_to_ida_prototype(
        "v24@0:8@16", "MyClass", "doSomething:", False)
    print(f"  v24@0:8@16 -> {proto}")

    proto2 = parser.method_to_ida_prototype(
        '@"NSArray"24@0:8q16', "MyClass", "itemsAtIndex:", False)
    print(f'  @"NSArray"24@0:8q16 -> {proto2}')

    # Test struct building
    print("\nStruct building test:")
    class_info = {
        "name": "FFAnchoredMediaComponent",
        "instanceSize": 0x80,
        "ivars": [
            {"name": "_displayName", "type": '@"NSString"', "offset": 0x48},
            {"name": "_timeRange", "type": "{CMTimeRange={CMTime=qiIq}{CMTime=qiIq}}", "offset": 0x50},
            {"name": "_isEnabled", "type": "B", "offset": 0x78},
        ]
    }
    struct_def = build_class_struct(class_info, parser)
    print(struct_def)

    print(f"\nDiscovered structs: {list(parser.discovered_structs.keys())}")
    print(f"\nAll tests passed: {all_passed}")
