# v4 parameter contract (params workstream)

Status: implementation contract, offline validation only. RPCs use the common v4 result envelope. No FCP launch, deployment, or live acceptance is implied.

## Shared addressing

```json
{
  "target": {"clip_id": "native-persistentID", "effect_instance_id": "native-fileUUID"},
  "parameter_path": "/effects/native-fileUUID/channels/9999/123/100",
  "time": {"value": 1001, "timescale": 30000, "space": "clip_local"}
}
```

`clip_id` is the clip's native `persistentID` string, never an index, display name, or bridge handle. Resolve it against the current active sequence and reject missing or ambiguous matches. `effect_instance_id` is the native effect `fileUUID` string, never `effectID`; omit it to inspect/address the whole clip including intrinsic components. No synthetic instance IDs. Missing native identity is unsupported.

Paths are returned by `v4.object.inspect` and must be copied verbatim. Components are `/effects/<JSON-pointer-escaped-fileUUID>/channels/<numeric-channelID>/...` or `/intrinsic/<component>/channels/<numeric-channelID>/...`. Intrinsic components: `transform`, `crop`, `trim`, `distort`, `compositing`, `audio` (gain) and `native` (remaining intrinsic channels). A channel root ID is included. No localized UI names, array ordinals, or guessed FCPXML keys. Duplicate sibling channel IDs are rejected.

Time is always explicit: signed 64-bit `value`, positive 32-bit `timescale`, `space` = `clip_local` or `timeline`. `clip_local` means native FCP component-local time, **not seconds since the visible trimmed start**. Timeline is the active sequence primary object's time coordinate and is converted by the host's `containerToLocalTime:container:`. Inspect/readback expose both coordinates and the channel time. No float seconds, implicit playhead, or time-zero fallback. These time mappings still need the live trimmed/retimed fixture.

## RPC inputs

- `v4.effect.catalog`: `{ "query": "", "type": "filter|audio|title|generator|transition", "category": "", "offset": 0, "limit": 100 }`. All filters optional; offset >= 0; limit 1..500. Full `effectID`, `type`, `category`, `localized_name`, `stable_name`, `template_path` (nullable), `package_uuid` (nullable), `payload_available` (nullable), stable pagination.
- `v4.effect.add`: `{ "target": {"clip_id":"..."}, "effect_id":"FULL catalog effectID" }`. Clip filter/audio insertion only; titles, generators, transitions need their dedicated insertion workflows. Readback contains the exact new `effect_instance_id` and complete ordered instance inventory.
- `v4.effect.remove`: `{ "target":{"clip_id":"...","effect_instance_id":"..."} }`.
- `v4.effect.enable`: previous shape plus `"enabled": false`.
- `v4.effect.move`: previous target plus `"before_instance_id":"..."` (same native section), or `"before_instance_id":null` to move to section end. Never a display-name/index target.
- `v4.object.inspect`: `{ "target":{"clip_id":"...","effect_instance_id":"..."}, "time":{"value":0,"timescale":1,"space":"clip_local"} }`. Effect identity optional. Readback includes `components` (recursive parameter tree), `effects` (ordered instance inventory), and `target`.
- `v4.parameter.describe`: shared addressing without `time` (optional); returns the same leaf metadata as inspect. No channel handle input.
- `v4.parameter.get`: shared addressing with required `time`.
- `v4.parameter.set`: shared addressing plus `"value":{"type":"double","value":0.5}` and `"mode":"at_time"` or `"constant"`. `at_time` edits just the specified time, preserving other keys. `constant` is accepted only for non-animated channels with no existing keyframes (or static strings); it never removes a curve. String writes require `constant`. The request still contains the explicit readback time. No replace-curve mode.
- `v4.keyframe.list`: shared addressing with required `time` (coordinate-space selection); returns all keys in that space, typed values, and native interpolation codes.
- `v4.keyframe.set`: same input as parameter.set, without `mode`; means a point write at the supplied time and requires an animatable channel. Readback must confirm a key exists at that exact time.
- `v4.keyframe.delete`: shared addressing with required `time`; deletes only that channel's key at that time. Missing key is a successful no-op.
- `v4.keyframe.set_interpolation`: shared addressing plus `"interpolation":"linear|hold|ease_in_out"`. Native engine codes are statically resolved: hold=0, linear=1, S-curve ease_in_out=21. Spatial Smooth tangent editing is unsupported and fails before mutation.

Reads optionally accept `operation_id`. Every integrated top-level mutation requires caller-owned `operation_id` and `expected_revision`; the core ledger binds ID and arguments durably. Nested mutations inherit the outer ID/revision/group. Optional `idempotency_key` is client correlation. Do not automatically repeat an unknown mutation with a new identity.

## Typed values and metadata

Value shapes: `{"type":"double|angle","value":1.25}`, `{"type":"int|enum","value":2}`, `{"type":"bool","value":false}`, `{"type":"string","value":"text"}`, `{"type":"point2d","value":{"x":1,"y":2}}`, `{"type":"point3d","value":{"x":1,"y":2,"z":3}}`, `{"type":"color","value":{"r":0.1,"g":0.2,"b":0.3,"a":1,"space":"native_curve"}}`. Integers must remain integers; bool is not a number. `native_curve` color values bypass UI display-space assumptions and may be HDR. Point2d is available only for native point channels with a verified ABI, otherwise edit discovered scalar children. Never assume display percent, pixels, dB, degrees, or enum ordinal-to-value mapping. Metadata includes `type`, `native_class`, `unit`, `data_range`, `ui_range`, `enum_options` (native numeric values plus localized labels), `animatable`, `coordinate_space`, `writable`, `children`; unknown metadata is null with explicit warnings.

Parameter get/set readback contains `target`, `parameter_path`, `time` (the exact request), `resolved_time` (native clip-local), and `value` (typed). Writes add `before`, `has_keyframe`, and `verified`. Readback is repeated after the native action group is saved; existing other-time keys are compared before and after a timed write. Native save failure reports applied:null and undo:unknown. Effect/keyframe operations read back their actual native state. A readback mismatch is an error with `applied:true`, never success. The integrated core supplies before/after revision tokens and stamps `native_group` only after observing ownership of the unchanged native top group. Domain action groups register inverses inside that core-owned outer group.
