"""Pure editorial validation and a checkpoint-compensated sequential executor."""

import copy
from fractions import Fraction

from .contracts import ContractError, result
from .registry import digest, load_schema, validate
from .timing import rational, snap_words

PLAN_SCHEMA = load_schema("edit_plan.schema.json")
CONTROL_FIELDS = {"expected_revision", "operation_id", "idempotency_key"}


class PlanEngine:
    def __init__(self, runtime):
        self.runtime = runtime

    def validate(self, plan):
        validate(PLAN_SCHEMA, plan)
        if rational(plan["frame_rate"]) <= 0:
            raise ContractError("INVALID_TIME", "Timeline frame rate must be positive")
        source_ids = [source["id"] for source in plan["sources"]]
        if len(source_ids) != len(set(source_ids)):
            raise ContractError("DUPLICATE_SOURCE", "Source IDs must be unique")
        sources = {source["id"]: source for source in plan["sources"]}
        for source in sources.values():
            if rational(source["frame_rate"]) <= 0 or rational(source["duration"]) <= 0:
                raise ContractError("INVALID_TIME", "Source duration and frame rate must be positive")
            words = source["words"]
            if len({word["id"] for word in words}) != len(words):
                raise ContractError("DUPLICATE_WORD", source["id"])
            previous_end = 0
            for word in words:
                start, end = rational(word["start"]), rational(word["end"])
                if start < previous_end or start >= end or end > rational(source["duration"]):
                    raise ContractError("INVALID_WORD_RANGE", word["id"])
                previous_end = end
        steps, ids = [], set()
        for operation in plan["operations"]:
            if operation["id"] in ids:
                raise ContractError("DUPLICATE_STEP", operation["id"])
            ids.add(operation["id"])
            cap = self.runtime.registry.get(operation["capability"])
            if cap.get("local_handler") or not cap.get("write_supported", False):
                raise ContractError("UNSUPPORTED_CAPABILITY", "Plan steps must be native write capabilities")
            if not cap["readback_supported"]:
                raise ContractError("READBACK_REQUIRED", cap["name"])
            family = cap['method'].removeprefix('v4.').removeprefix('fixture.').split('.')[0]
            allowed = {'cut': {'timeline'}, 'title': {'title', 'caption', 'generator'},
                       'effect': {'effect', 'color', 'audio'}, 'parameter': {'parameter', 'keyframe', 'audio', 'retime'},
                       'transition': {'transition'}}
            if family not in allowed[operation['kind']]:
                raise ContractError('UNSUPPORTED_CAPABILITY', 'Operation kind does not match the native capability family')
            properties = cap["input_schema"].get("properties", {})
            if not CONTROL_FIELDS.issubset(properties):
                raise ContractError("OPERATION_CONTRACT_REQUIRED", f"{cap['name']} must accept {sorted(CONTROL_FIELDS)}")
            args = copy.deepcopy(operation["args"])
            if CONTROL_FIELDS.intersection(args):
                raise ContractError("INVALID_CONTROL", "The executor owns revision and operation identity")
            targets = [args[key] for key in ("clip_id", "target_id", "left_clip_id", "right_clip_id") if key in args]
            if isinstance(args.get('target'), dict) and 'clip_id' in args['target']:
                targets.append(args['target']['clip_id'])
            if isinstance(args.get('cut'), dict):
                targets.extend(args['cut'][key] for key in ('left_clip_id', 'right_clip_id') if key in args['cut'])
            if any(target not in plan["scope"]["target_ids"] for target in targets):
                raise ContractError("OUT_OF_SCOPE", operation["id"])
            if args.get("ripple", False) and not plan["scope"]["allow_ripple"]:
                raise ContractError("RIPPLE_FORBIDDEN", operation["id"])
            if operation["kind"] == "cut":
                source = sources.get(args["source_id"])
                if source is None:
                    raise ContractError("SOURCE_NOT_FOUND", args["source_id"])
                expected = snap_words(args["word_ids"], source["words"], source["frame_rate"])
                if any(rational(args["source_range"][key]) != rational(expected[key]) for key in ("start", "end")):
                    raise ContractError("WORD_BOUNDARY_MISMATCH", f"Expected outward frame-aligned word range {expected}")
                if rational(expected["end"]) > rational(source["duration"]):
                    raise ContractError("OUT_OF_SOURCE_RANGE", operation["id"])
            for key in ("source_range", "timeline_range"):
                if key in args:
                    start, end = (rational(args[key][bound]) for bound in ("start", "end"))
                    if start < 0 or end <= start:
                        raise ContractError("INVALID_TIME", operation["id"])
                    rate = sources[args["source_id"]]["frame_rate"] if key == "source_range" else plan["frame_rate"]
                    if any((time * rational(rate)).denominator != 1 for time in (start, end)):
                        raise ContractError("FRAME_ALIGNMENT", operation["id"])
            if "duration" in args:
                value = args['duration']
                if isinstance(value, dict) and set(value) == {'value', 'timescale'}:
                    if any(type(value[key]) is not int for key in value) or value['timescale'] <= 0:
                        raise ContractError('INVALID_TIME', 'Native duration requires integer value and positive timescale')
                    duration = Fraction(value['value'], value['timescale'])
                else:
                    duration = rational(value)
                if duration <= 0 or (duration * rational(plan["frame_rate"])).denominator != 1:
                    raise ContractError("FRAME_ALIGNMENT", operation["id"])
            checked_args = {**args, "expected_revision": plan["base_revision"],
                            "operation_id": self.runtime.operation_id("validation/" + operation["id"]),
                            "idempotency_key": "validation-only"}
            validate(cap["input_schema"], checked_args)
            steps.append({"id": operation["id"], "kind": operation["kind"],
                          "capability": cap["name"], "schema_hash": cap["schema_hash"],
                          "args": args})
        return {"plan_hash": digest(plan), "base_revision": plan["base_revision"],
                "steps": steps, "atomicity": "checkpoint_compensated",
                "verification": {"structure": "offline_validated", "visual": "not_checked", "audio": "not_checked"}}

    def preview_diff(self, plan):
        checked = self.validate(plan)
        return {**checked, "changes": [
            {"step_id": step["id"], "kind": step["kind"], "capability": step["capability"],
             "proposed": step["args"]} for step in checked["steps"]],
            "warnings": ["Semantic intent only; actual native differences come from per-step readback."]}

    def apply(self, plan, idempotency_key):
        checked = self.validate(plan)
        fingerprint = checked["plan_hash"]
        if not idempotency_key:
            raise ContractError("INVALID_IDEMPOTENCY_KEY", "A nonempty idempotency key is required")
        prior = self.runtime.plans.get(idempotency_key)
        if prior:
            if prior["fingerprint"] != fingerprint:
                raise ContractError("IDEMPOTENCY_CONFLICT", "The key is already bound to another plan")
            return copy.deepcopy(prior["result"])
        self.runtime.require_writable()
        # Observational native checkpoints must never be mistaken for a
        # restorable snapshot. Reject the missing integration before any write.
        self.runtime.require_binding('history.restore')
        state = self.runtime.state_data()
        self.runtime.assert_identity(state, plan["project_id"], plan["sequence_id"], plan["base_revision"])
        if rational(state.get("frame_rate")) != rational(plan["frame_rate"]):
            raise ContractError("FRAME_RATE_MISMATCH", "Plan frame rate differs from native timeline state")
        # The model cannot invent transcript timings, source rates, or target IDs.
        observed_sources = {source["id"]: source for source in state.get("sources", [])}
        for source in plan["sources"]:
            observed = observed_sources.get(source["id"])
            # Native state may also carry paths/text/probe metadata. Compare the
            # complete ordered structural evidence, not incidental display fields.
            canonical = None if observed is None else {
                **{key: observed[key] for key in ("id", "duration", "frame_rate")},
                "words": [{key: word[key] for key in ("id", "start", "end")} for word in observed["words"]],
            }
            if canonical != source:
                raise ContractError("SOURCE_EVIDENCE_MISMATCH", source["id"])
        if not set(plan["scope"]["target_ids"]).issubset(state.get("target_ids", [])):
            raise ContractError("TARGET_NOT_FOUND", "Scope must be present in fresh native state")
        # Check every build scope before creating a checkpoint or touching the timeline.
        for step in checked["steps"]:
            self.runtime.check_build(self.runtime.registry.get(step["capability"]))
        restore_cap = self.runtime.require_binding("history.restore")
        if not restore_cap.get("write_supported") or not restore_cap["readback_supported"]:
            raise ContractError("CHECKPOINT_NOT_RESTORABLE", "Native restore must be a readback-supported write capability")
        if not (CONTROL_FIELDS | {"checkpoint_id"}).issubset(restore_cap["input_schema"].get("properties", {})):
            raise ContractError("OPERATION_CONTRACT_REQUIRED", "Native restore must accept checkpoint and operation identity")
        self.runtime.check_build(restore_cap)
        checkpoint = self.runtime.bootstrap("history.checkpoint", {
            "project_id": plan["project_id"], "sequence_id": plan["sequence_id"],
            "expected_revision": plan["base_revision"], "label": "EditPlan " + fingerprint[:12]})
        if not checkpoint["ok"]:
            return checkpoint
        cp = checkpoint.get("readback") or {}
        if (not cp.get("checkpoint_id") or cp.get("restorable") is not True
                or cp.get("revision") != plan["base_revision"]):
            raise ContractError("CHECKPOINT_NOT_RESTORABLE", "Native checkpoint must confirm restorable baseline identity")
        revision, outputs = plan["base_revision"], []
        op_id = self.runtime.operation_id("plan/" + idempotency_key)
        # Save an UNKNOWN marker before sending any write; never silently replay a partial plan.
        pending = result(False, operation_id=op_id, applied=None, code="UNKNOWN_OUTCOME",
                         message="Plan execution has not completed")
        self.runtime.plans[idempotency_key] = {"fingerprint": fingerprint, "result": pending}
        self.runtime.operations[op_id] = copy.deepcopy(pending)
        outcome = None
        for step in checked["steps"]:
            args = {**step["args"], "expected_revision": revision,
                    "operation_id": self.runtime.operation_id(idempotency_key + "/" + step["id"]),
                    "idempotency_key": idempotency_key + "/" + step["id"]}
            response = self.runtime.execute(step["capability"], args)
            outputs.append({"step_id": step["id"], "result": response})
            if not response["ok"]:
                if response["applied"] is None:
                    outcome = result(False, operation_id=op_id, applied=None, before=plan["base_revision"],
                                     code="UNKNOWN_OUTCOME", message="Reconcile the native operation before restoration or retry",
                                     readback={"steps": outputs, "checkpoint_id": cp["checkpoint_id"], "rollback": "deferred"})
                    break
                if response["applied"] is True:
                    revision = response.get("revision_after")
                restore = self.runtime.bootstrap("history.restore", {
                    "checkpoint_id": cp["checkpoint_id"], "expected_revision": revision})
                restored = restore["ok"] and (restore.get("readback") or {}).get("revision") == plan["base_revision"]
                if not restored:
                    self.runtime.unknown.add(op_id)
                outcome = result(False, operation_id=op_id, applied=False if restored else None,
                                 before=plan["base_revision"], after=plan["base_revision"] if restored else None,
                                 code="PLAN_STEP_FAILED" if restored else "ROLLBACK_FAILED",
                                 message="Step failed; checkpoint restored" if restored else "Checkpoint restoration was not verified",
                                 readback={"steps": outputs, "checkpoint_id": cp["checkpoint_id"], "rollback": restore})
                break
            revision = response["revision_after"]
        if outcome is None:
            outcome = result(operation_id=op_id, applied=any(item["result"]["applied"] for item in outputs),
                             before=plan["base_revision"], after=revision,
                             readback={"steps": outputs, "checkpoint_id": cp["checkpoint_id"],
                                       "verification": {"structure": "readback_verified", "visual": "not_checked", "audio": "not_checked"}})
        self.runtime.plans[idempotency_key]["result"] = copy.deepcopy(outcome)
        self.runtime.operations[op_id] = copy.deepcopy(outcome)
        return outcome
