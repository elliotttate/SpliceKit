"""Regenerate the params capability manifest; uses only the Python standard library."""
import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT/'mcp'))
from splicekit_v4.envelope import RESULT_SCHEMA

NULL = {"type": "null"}
S = {"type": "string", "minLength": 1}
B = {"type": "boolean"}
I = {"type": "integer"}
N = {"type": "number"}

def obj(properties, required=(), extra=False):
    return {"type": "object", "properties": properties, "required": list(required), "additionalProperties": extra}

def nullable(schema):
    return {"anyOf": [schema, NULL]}

TIME = obj({"value": {"type": "integer", "minimum": -(2**63), "maximum": 2**63-1},
            "timescale": {"type": "integer", "minimum": 1, "maximum": 2**31-1},
            "space": {"enum": ["clip_local", "timeline"]}}, ("value", "timescale", "space"))
TIME["description"] = "Native component-local coordinates (not zero at trimmed visible start), or active primary sequence coordinates. No implicit playhead/source time."
TARGET = obj({"clip_id": S, "effect_instance_id": S}, ("clip_id",))
TARGET["description"] = "Native clip persistentID and optional exact effect persistentID (legacy fileUUID only when absent); never a name, array index, effectID or handle."
EXACT = obj(TARGET["properties"], ("clip_id", "effect_instance_id"))
CLIP = obj({"clip_id": S}, ("clip_id",))
PATH = {"type": "string", "pattern": "^/(effects/[^/]+|intrinsic/[^/]+)/channels/[0-9]+(/[0-9]+)*$", "description": "Copy stable numeric channel-ID path from object.inspect; instance segment uses JSON Pointer escaping."}

def typed(t, value):
    return obj({"type": {"const": t}, "value": value}, ("type", "value"))

VALUE = {"oneOf": [typed(t, N) for t in ["double", "angle"]] + [
    typed(t, {"type": "integer", "minimum": -(2**31), "maximum": 2**31-1}) for t in ["int", "enum"]] + [
    typed("bool", B), typed("string", {"type": "string"}),
    typed("point2d", obj({"x": N, "y": N}, ("x", "y"))),
    typed("point3d", obj({"x": N, "y": N, "z": N}, ("x", "y", "z"))),
    typed("color", obj({"r": N, "g": N, "b": N, "a": N, "space": {"const": "native_curve"}}, ("r", "g", "b", "a", "space"))) ]}
RANGE = obj({"min": nullable({"type":["number", "boolean"]}), "max": nullable({"type":["number", "boolean"]})}, ("min", "max"))
LEAF_FIELDS = {"parameter_path": PATH, "channel_id": I, "localized_name": {"type":"string"},
               "native_class": S, "type": {"enum": ["double", "angle", "int", "enum", "bool", "string", "point2d", "point3d", "color", "container"]},
               "unit": nullable(S), "coordinate_space": nullable(S), "data_range": RANGE, "ui_range": RANGE,
               "enum_options": nullable({"type":"array", "items": obj({"value":I, "localized_label":{"type":"string"}}, ("value","localized_label"))}),
               "animatable": B, "writable": B, "interpolations": {"type":"array", "items":{"enum":["linear","hold","ease_in_out"]}},
               "time_space":{"const":"clip_local"}, "slider_transformer":nullable({"type":"string"}),
               "children":{"type":"array", "items":{"$ref":"#/$defs/node"}}}
NODE = obj(LEAF_FIELDS, LEAF_FIELDS)
NODE['properties']['alpha_supported'] = B
EFFECT = obj({"effect_instance_id": S, "effectID":nullable(S), "localized_name":{"type":"string"}, "enabled":nullable(B), "section":nullable(I), "index_in_section":nullable(I)}, ("effect_instance_id","effectID","localized_name","enabled","section","index_in_section"))
EFFECTS = {"type":"array", "items":EFFECT}
READ = obj({"target": TARGET, "parameter_path":PATH, "time":TIME, "resolved_time":TIME, "channel_time":TIME, "value":VALUE, "has_keyframe":B,
            "before":VALUE, "verified":B}, ("target","parameter_path","time","resolved_time","channel_time","value","has_keyframe"))
KEYS = {"type":"array", "items":obj({"time":TIME,"resolved_time":TIME,"value":VALUE,"native_interpolation":nullable(I)}, ("time","resolved_time","value","native_interpolation"))}

def envelope(readback):
    import copy
    schema = copy.deepcopy(RESULT_SCHEMA)
    schema["$defs"] = {"readback": readback}
    if "#/$defs/node" in json.dumps(readback): schema["$defs"]["node"] = NODE
    schema["allOf"] = [{"if": {"allOf": [
        {"properties": {"ok": {"const": True}}},
        {"not": {"required": ["status"], "properties": {"status": {"const": "pending"}}}}
    ]}, "then": {"properties": {"readback": {"$ref": "#/$defs/readback"}}}}]
    return schema

def input_schema(fields, required):
    return obj({"operation_id":S,**fields},required)

entries=[]
def capability(name, description, inputs, outputs, write=False):
    inputs['properties'].update(operation_id={"type":"string","minLength":1,"maxLength":200},
                                expected_revision={"type":"string","minLength":1})
    if write:
        inputs['properties']['idempotency_key']={"type":"string","minLength":1,
            "description":"Optional client correlation; operation_id is the native durable idempotency key."}
        inputs['required']=list(dict.fromkeys(inputs.get('required',[])+['operation_id','expected_revision']))
    entries.append({"schema_version":1,"name":name,"method":name,"category":name.split('.')[1],
                    "description":description,"input_schema":inputs,"output_schema":envelope(outputs),
                    "backend":"native_objc","undo_kind":"native_group" if write else "none",
                    "read_supported":not write,"write_supported":write,"readback_supported":True,
                    "requires_fcp_build":["454072"],"evidence_level":"offline_tested",
                    "atomicity":"native_undo_group_no_rollback" if write else "read_only",
                    "operation_kind":"mutation" if write else "read",
                    "known_limitations":["Live native undo, persistence and visual/audio output are unverified."]})

catalog_row=obj({"effectID":S,"type":S,"native_type":nullable(S),"category":{"type":"string"},"localized_name":S,
                 "stable_name":S,"stable_name_source":{"const":"effectID"},"template_path":nullable(S),"package_uuid":nullable(S),"payload_available":nullable(B)},
                ("effectID","type","category","localized_name","stable_name","stable_name_source","template_path","package_uuid","payload_available"))
capability("v4.effect.catalog","Page/filter the active registry without truncating IDs. stable_name is the full effectID, not an unverified English display name.",
           input_schema({"query":{"type":"string"},"type":{"enum":["filter","audio","title","generator","transition"]},"category":{"type":"string"},"offset":{"type":"integer","minimum":0},"limit":{"type":"integer","minimum":1,"maximum":500}},()),
           obj({"effects":{"type":"array","items":catalog_row},"total":I,"offset":I,"limit":I,"next_offset":nullable(I)},("effects","total","offset","limit","next_offset")))
for op,fields,required in [
    ("add",{"target":CLIP,"effect_id":S},("target","effect_id")),
    ("remove",{"target":EXACT},("target",)),
    ("enable",{"target":EXACT,"enabled":B},("target","enabled")),
    ("move",{"target":EXACT,"before_instance_id":nullable(S)},("target","before_instance_id"))]:
    output=obj({"target":EXACT,"effects":EFFECTS,"before":EFFECTS,"enabled":B},("target","effects","before"),False)
    capability("v4.effect."+op,"Exact-instance "+op+". move stays within one native section; add accepts filter/audio types only.",input_schema(fields,required),output,True)
inspect_output=obj({"target":TARGET,"components":{"type":"array","items":obj({"component_path":S,"available":B,"children":{"type":"array","items":{"$ref":"#/$defs/node"}}},("component_path","available","children"))},
                    "bindings":{"type":"object","additionalProperties":PATH},"values":{"type":"object","additionalProperties":VALUE},"effects":EFFECTS,"time":TIME,"resolved_time":TIME},
                   ("target","components","bindings","values","effects","time","resolved_time"))
capability("v4.object.inspect","Discover the identity-bound channel-ID tree including present transform, crop/trim/Ken Burns, distort, compositing and gain. Absent intrinsic effects are not created.",input_schema({"target":TARGET,"time":TIME},("target","time")),inspect_output)
base={"target":TARGET,"parameter_path":PATH,"time":TIME}
capability("v4.parameter.describe","Return metadata leaf directly at readback root. Null means unknown, never a guessed unit/range/enum ordinal.",input_schema(base,("target","parameter_path")),NODE)
capability("v4.parameter.get","Read a typed native curve value at explicit rational time.",input_schema(base,base),READ)
capability("v4.parameter.set","Write typed native value and read the same time. constant refuses existing curves; at_time preserves other keys. String is constant-only.",input_schema({**base,"value":VALUE,"mode":{"enum":["at_time","constant"]}},(*base,"value","mode")),READ,True)
key_fields={"target":TARGET,"parameter_path":PATH,"time":TIME,"keyframes":KEYS,"deleted":B,"native_interpolation":I}
key_output=obj(key_fields,("target","parameter_path","time","keyframes"))
capability("v4.keyframe.list","List exact scalar channel keys in explicitly requested time space; use scalar children for compound curves.",input_schema(base,base),key_output)
capability("v4.keyframe.set","Set one typed time point, preserve other keys, confirm has_keyframe and same-time typed value.",input_schema({**base,"value":VALUE},(*base,"value")),READ,True)
capability("v4.keyframe.delete","Delete only this channel's key at this time. Missing key is a successful applied:false no-op.",input_schema(base,base),key_output,True)
capability("v4.keyframe.set_interpolation","Set outgoing scalar segment mode. 0 hold, 1 linear, 21 engine S-curve ease_in_out; spatial Smooth is not exposed.",input_schema({**base,"interpolation":{"enum":["linear","hold","ease_in_out"]}},(*base,"interpolation")),key_output,True)
manifest={"schema_version":1,"workstream":"params","contract":"docs/v4/PARAMS-CONTRACT.md","capabilities":entries}
(ROOT/'mcp/splicekit_v4/capabilities/params.json').write_text(json.dumps(manifest,indent=2)+"\n")
if __name__=='__main__': print(f'Wrote {len(entries)} capability schemas')
