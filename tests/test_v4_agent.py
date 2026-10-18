"""Offline fault injection and discovery tests; never connects to a native host."""

import copy
import importlib.util
import json
import os
import socket
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "mcp"))
sys.path.insert(0, str(ROOT / "examples" / "v4"))

from splicekit_v4.contracts import ContractError, result
from splicekit_v4.registry import CapabilityRegistry, check_schema, digest, validate, load_schema
from splicekit_v4.timing import frame_snap, rational, snap_words, source_to_timeline
from offline_host import example_plan, make_runtime
from gemini_edit_loop import DryRunModel, invoke, run_loop, validate_critique


class AgentTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.runtime, self.host = make_runtime(self.temp.name)
        self.plan = example_plan()

    def apply(self, plan=None, key="test/plan"):
        return invoke(self.runtime, "plan.apply", {"plan": plan or self.plan, "idempotency_key": key})

    def invoke_result(self, name, args):
        self.runtime.capability_search(name, limit=50)
        descriptor = self.runtime.capability_describe(name)["readback"]
        return self.runtime.capability_invoke(name, args, descriptor["schema_hash"])

    def capture(self, **overrides):
        request = {"project_id": "fixture-project", "sequence_id": "fixture-sequence", "expected_revision": "r0",
                   "mode": "viewer_frame", "range": {"start": {"num": 0, "den": 1}, "end": {"num": 1, "den": 1}}}
        request.update(overrides)
        return self.invoke_result("review.capture", {"request": request})

    def test_registry_loads_all_files_and_excludes_fixture_from_shipped_catalog(self):
        self.assertEqual(len(self.runtime.registry), 13)
        shipped = CapabilityRegistry()
        self.assertEqual(shipped.search("fixture")["total"], 0)
        self.assertEqual(len(shipped), 53)

    def test_discovery_then_description_then_schema_hash_is_required(self):
        self.assertFalse(self.runtime.capability_describe("parameter.set")["ok"])
        self.runtime.capability_search("parameter.set")
        cap = self.runtime.registry.get("parameter.set")
        response = self.runtime.capability_invoke(cap["name"], {}, cap["schema_hash"])
        self.assertEqual(response["error"]["code"], "DESCRIPTION_REQUIRED")
        self.runtime.capability_describe(cap["name"])
        response = self.runtime.capability_invoke(cap["name"], {}, "obsolete-hash")
        self.assertEqual(response["error"]["code"], "DESCRIPTION_REQUIRED")
        self.assertEqual(self.host.calls, [])

    def test_search_is_bounded_and_category_filtered(self):
        found = self.runtime.capability_search("", limit=1)
        self.assertTrue(found["readback"]["truncated"])
        self.assertEqual(len(found["readback"]["matches"]), 1)
        self.assertEqual(self.runtime.capability_search("", category="plan")["readback"]["total"], 3)
        self.assertFalse(self.runtime.capability_search(limit=1000)["ok"])

    def test_invalid_arguments_do_not_dispatch(self):
        response = self.invoke_result("parameter.set", {"target_id": "clip-1", "value": 1})
        self.assertEqual(response["error"]["code"], "SCHEMA_VALIDATION")
        self.assertEqual(self.host.calls, [])

    def test_unknown_build_and_static_evidence_do_not_dispatch_mutation(self):
        original = self.host.call
        def other_build(method, **args):
            return {"fcp_build": "other-build"} if method == "system.version" else original(method, **args)
        with patch.object(self.host, "call", side_effect=other_build):
            response = self.invoke_result("plan.apply", {"plan": self.plan, "idempotency_key": "build"})
        self.assertEqual(response["error"]["code"], "UNSUPPORTED_FCP_BUILD")
        self.assertEqual(self.host.state["revision"], "r0")
        self.assertFalse(self.host.checkpoints)
        self.runtime.registry._items["parameter.set"]["evidence_level"] = "static"
        response = self.invoke_result("plan.apply", {"plan": self.plan, "idempotency_key": "static"})
        self.assertEqual(response["error"]["code"], "INSUFFICIENT_EVIDENCE")

    def test_validation_and_preview_never_contact_host(self):
        checked = self.invoke_result("plan.validate", {"plan": self.plan})
        preview = self.invoke_result("plan.preview_diff", {"plan": self.plan})
        self.assertTrue(checked["ok"])
        self.assertEqual(preview["readback"]["plan_hash"], digest(self.plan))
        self.assertEqual([item["kind"] for item in preview["readback"]["changes"]], ["cut", "parameter"])
        self.assertEqual(self.host.calls, [])

    def test_invalid_later_step_and_unrestorable_checkpoint_prevent_any_edit(self):
        plan = copy.deepcopy(self.plan)
        plan["operations"][1]["args"].pop("parameter_id")
        self.assertFalse(self.invoke_result("plan.apply", {"plan": plan, "idempotency_key": "invalid-later"})["ok"])
        self.assertEqual(self.host.calls, [])
        original = self.host.call
        def unrestorable(method, **args):
            response = original(method, **args)
            if method == "v4.fixture.history.checkpoint":
                response["readback"]["restorable"] = False
            return response
        with patch.object(self.host, "call", side_effect=unrestorable):
            response = self.invoke_result("plan.apply", {"plan": self.plan, "idempotency_key": "unrestorable"})
        self.assertEqual(response["error"]["code"], "CHECKPOINT_NOT_RESTORABLE")
        self.assertFalse(self.host.state["changes"])

    def test_all_editorial_kinds_validate(self):
        for kind, name, args in [
            ("title", "title.set_text", {"target_id": "clip-1", "text": "Hello", "timeline_range": {"start": {"num": 0,"den": 1}, "end": {"num": 1,"den": 1}}}),
            ("effect", "effect.add", {"target_id": "clip-1", "effect_id": "effect-1", "parameters": {"amount": 0.3}}),
            ("transition", "transition.set", {"left_clip_id": "clip-1", "right_clip_id": "clip-2", "duration": {"num": 1,"den": 2}}),
        ]:
            with self.subTest(kind=kind):
                plan = copy.deepcopy(self.plan)
                plan["operations"] = [{"id": kind, "kind": kind, "capability": name, "args": args}]
                self.assertTrue(self.invoke_result("plan.validate", {"plan": plan})["ok"])

    def test_bad_word_scope_time_or_duplicate_step_rejected(self):
        for modify, code in [
            (lambda p: p["operations"][0]["args"].update(word_ids=["absent"]), "WORD_NOT_FOUND"),
            (lambda p: p["operations"][0]["args"]["source_range"].update(end={"num": 3,"den": 1}), "WORD_BOUNDARY_MISMATCH"),
            (lambda p: p["operations"][1]["args"].update(target_id="unowned"), "OUT_OF_SCOPE"),
            (lambda p: p["operations"].append(copy.deepcopy(p["operations"][0])), "DUPLICATE_STEP"),
            (lambda p: p["operations"][0]["args"].update(operation_id="injected"), "INVALID_CONTROL"),
        ]:
            with self.subTest(code=code):
                plan = copy.deepcopy(self.plan)
                modify(plan)
                response = self.invoke_result("plan.validate", {"plan": plan})
                self.assertEqual(response["error"]["code"], code)

    def test_apply_is_ordered_revision_chained_and_duplicate_is_not_replayed(self):
        response = self.apply()
        self.assertTrue(response["ok"])
        self.assertEqual(response["revision_after"], "r2")
        writes = [(method, args) for method,args in self.host.calls if method in ("v4.fixture.timeline.trim", "v4.fixture.parameter.set")]
        self.assertEqual([args["expected_revision"] for _,args in writes], ["r0", "r1"])
        count = len(self.host.calls)
        self.assertEqual(self.apply(), response)
        self.assertEqual(len(self.host.calls), count)

    def test_idempotency_conflict_rejected(self):
        self.apply()
        changed = copy.deepcopy(self.plan)
        changed["operations"][1]["args"]["value"] = 0.7
        response = self.invoke_result("plan.apply", {"plan": changed, "idempotency_key": "test/plan"})
        self.assertEqual(response["error"]["code"], "IDEMPOTENCY_CONFLICT")

    def test_stale_identity_and_forged_source_evidence_prevent_checkpoint(self):
        for modify, code in [
            (lambda s: s.update(revision="external"), "STALE_REVISION"),
            (lambda s: s.update(project_id="other"), "TARGET_MISMATCH"),
            (lambda s: s.update(sources=[]), "SOURCE_EVIDENCE_MISMATCH"),
            (lambda s: s.update(target_ids=[]), "TARGET_NOT_FOUND"),
        ]:
            with self.subTest(code=code):
                saved = copy.deepcopy(self.host.state)
                modify(self.host.state)
                response = self.invoke_result("plan.apply", {"plan": self.plan, "idempotency_key": code})
                self.assertEqual(response["error"]["code"], code)
                self.assertFalse(self.host.checkpoints)
                self.host.state = saved

    def test_known_failure_restores_owned_checkpoint(self):
        baseline = copy.deepcopy(self.host.state)
        self.host.fail_method = "v4.fixture.parameter.set"
        response = self.invoke_result("plan.apply", {"plan": self.plan, "idempotency_key": "fail"})
        self.assertEqual(response["error"]["code"], "PLAN_STEP_FAILED")
        self.assertEqual(self.host.state, baseline)
        self.assertFalse(response["applied"])
        restore = [args for method,args in self.host.calls if method == "v4.fixture.history.restore"]
        self.assertEqual(restore[0]["expected_revision"], "r1")

    def test_timeout_does_not_restore_or_replay_and_blocks_new_writes(self):
        self.host.timeout_method = "v4.fixture.parameter.set"
        response = self.invoke_result("plan.apply", {"plan": self.plan, "idempotency_key": "timeout"})
        self.assertEqual(response["error"]["code"], "UNKNOWN_OUTCOME")
        self.assertIsNone(response["applied"])
        self.assertTrue(self.runtime.unknown)
        self.assertFalse(any(method == "v4.fixture.history.restore" for method,_ in self.host.calls))
        count = len(self.host.calls)
        self.invoke_result("plan.apply", {"plan": self.plan, "idempotency_key": "timeout"})
        self.assertEqual(len(self.host.calls), count)
        blocked = self.invoke_result("plan.apply", {"plan": self.plan, "idempotency_key": "new-plan"})
        self.assertEqual(blocked["error"]["code"], "UNKNOWN_OUTCOME")

    def test_missing_readback_is_unknown_instead_of_success(self):
        self.host.bad_readback = True
        response = self.invoke_result("plan.apply", {"plan": self.plan, "idempotency_key": "bad-readback"})
        self.assertEqual(response["error"]["code"], "UNKNOWN_OUTCOME")
        self.assertEqual(len(self.host.state["changes"]), 1)

    def test_only_explicit_matching_native_reconciliation_clears_unknown(self):
        operation_id = "unknown-operation"
        self.runtime.unknown.add(operation_id)
        cached = result(False, operation_id=operation_id, applied=None, code="UNKNOWN_OUTCOME", message="Timeout")
        self.runtime.operations[operation_id] = cached
        self.runtime.operation_status(operation_id)
        self.assertIn(operation_id, self.runtime.unknown)
        original = self.host.call
        def reconciled(method, **args):
            if method == "v4.fixture.operation.status":
                return result(readback={"operation": result(operation_id=operation_id, applied=False), "reconciled": True})
            return original(method, **args)
        with patch.object(self.host, "call", side_effect=reconciled):
            self.runtime.operation_status(operation_id)
        self.assertNotIn(operation_id, self.runtime.unknown)

    def test_failed_restore_stays_unknown(self):
        original = self.host.call
        def failing(method, **args):
            if method in ("v4.fixture.parameter.set", "v4.fixture.history.restore"):
                return result(False, operation_id=args["operation_id"], code="INJECTED_FAILURE", message="Failure")
            return original(method, **args)
        with patch.object(self.host, "call", side_effect=failing):
            response = self.invoke_result("plan.apply", {"plan": self.plan, "idempotency_key": "restore-fail"})
        self.assertEqual(response["error"]["code"], "ROLLBACK_FAILED")
        self.assertTrue(self.runtime.unknown)

    def test_unsupported_host_build_fails_without_legacy_fallback(self):
        from splicekit_v4.runtime import AgentRuntime
        runtime = AgentRuntime(self.host)
        self.assertEqual(runtime.state_read()["error"]["code"], "UNSUPPORTED_FCP_BUILD")
        self.assertEqual([method for method, _ in self.host.calls], ["system.version"])

    def test_incompatible_restore_contract_is_rejected_before_checkpoint(self):
        self.runtime.registry._items["history.restore"]["input_schema"]["properties"].pop("operation_id")
        response = self.invoke_result("plan.apply", {"plan": self.plan, "idempotency_key": "bad-restore-contract"})
        self.assertEqual(response["error"]["code"], "OPERATION_CONTRACT_REQUIRED")
        self.assertFalse(self.host.checkpoints)
        self.assertFalse(self.host.state["changes"])

    def test_review_artifact_bound_to_revision_hash_and_native_viewer(self):
        response = self.capture()
        artifact = response["readback"]["artifact"]
        self.assertFalse(artifact["native"])
        self.assertTrue(artifact["synthetic"])
        self.assertEqual(artifact["revision"], "r0")
        self.assertEqual(artifact["evidence_level"], "offline_tested")
        self.assertFalse(artifact["has_audio"])
        import hashlib
        self.assertEqual(artifact["sha256"], hashlib.sha256(Path(artifact["path"]).read_bytes()).hexdigest())
        saved = json.loads(Path(artifact["path"]).with_suffix(".json").read_text())
        self.assertEqual(saved, artifact)
        self.assertEqual([args["viewer"] for method,args in self.host.calls if method == "viewer.capture"], ["normal"])

    def test_successful_native_noop_requires_readback_and_unchanged_revision(self):
        original = self.host.call
        def no_op(method, **args):
            if method in ("v4.fixture.timeline.trim", "v4.fixture.parameter.set"):
                return result(operation_id=args["operation_id"], applied=False, readback=copy.deepcopy(self.host.state),
                              before=self.host.state["revision"], after=self.host.state["revision"])
            return original(method, **args)
        with patch.object(self.host, "call", side_effect=no_op):
            response = self.apply(key="native-no-op")
        self.assertTrue(response["ok"])
        self.assertFalse(response["applied"])
        self.assertEqual(response["revision_after"], "r0")

    def test_review_refuses_source_viewer_playback_and_share_dialog(self):
        for field,value in (("viewer_ready", False), ("playing", True), ("viewer_sequence_id", "browser-source")):
            with self.subTest(field=field):
                saved = copy.deepcopy(self.host.state)
                self.host.state[field] = value
                self.assertFalse(self.capture()["ok"])
                self.host.state = saved
        response = self.capture(mode="native_share")
        self.assertEqual(response["error"]["code"], "NATIVE_SHARE_UNVERIFIED")
        self.assertFalse(any(method == "share.export" for method,_ in self.host.calls))

    def test_review_detects_revision_race(self):
        original = self.host.call
        def race(method, **args):
            response = original(method, **args)
            if method == "viewer.capture":
                self.host.state["revision"] = "external-edit"
            return response
        with patch.object(self.host, "call", side_effect=race):
            response = self.capture()
        self.assertEqual(response["error"]["code"], "STALE_REVISION")

    def test_dry_model_loop_makes_no_network_calls(self):
        with patch.object(socket, "create_connection", side_effect=AssertionError("No network")), \
                patch("urllib.request.urlopen", side_effect=AssertionError("No model call")):
            report = run_loop(self.runtime, DryRunModel(), "fixture brief", None)
        self.assertEqual(len(report["rounds"]), 2)
        self.assertEqual(self.host.state["revision"], "r3")
        self.assertFalse(report["native_live_verified"])

    def test_critique_rejects_unsupported_operations_and_unseen_evidence(self):
        artifact = self.capture()["readback"]["artifact"]
        context = {"capabilities": [self.runtime.registry.get("parameter.set")], "state": self.host.state}
        critique = DryRunModel().critique("brief", context, artifact)
        validate_critique(critique, context, artifact)
        for field,value in (("suggested_operation","lua.execute"), ("evidence_ref","stale"), ("target_id","foreign")):
            with self.subTest(field=field):
                invalid = copy.deepcopy(critique)
                invalid["issues"][0][field] = value
                with self.assertRaises(ContractError):
                    validate_critique(invalid, context, artifact)


class RegistrySchemaTests(unittest.TestCase):
    def test_duplicate_invalid_unsafe_and_external_ref_manifests_rejected(self):
        fixture = json.loads((ROOT / "examples/v4/fixtures/native-capabilities.json").read_text())["capabilities"][0]
        mutations = [lambda c: c.update(evidence_level="invented"), lambda c: c.pop("input_schema"),
                     lambda c: c.update(method="debug.eval"),
                     lambda c: c.update(output_schema={"$ref": "https://example.invalid/schema"})]
        for modify in mutations:
            with self.subTest(modify=modify), tempfile.TemporaryDirectory() as directory:
                entry = copy.deepcopy(fixture)
                modify(entry)
                Path(directory,"bad.json").write_text(json.dumps(entry))
                with self.assertRaises((ContractError, ValueError)):
                    CapabilityRegistry(directory)
        with tempfile.TemporaryDirectory() as directory:
            for name in ("one", "two"):
                Path(directory,name+".json").write_text(json.dumps(fixture))
            with self.assertRaisesRegex(ContractError, "state.read"):
                CapabilityRegistry(directory)

    def test_missing_local_ref_and_nonfinite_json_rejected(self):
        with self.assertRaises(ContractError):
            check_schema({"$ref": "#/$defs/absent"})
        with self.assertRaises(ContractError):
            validate({"type":"number"}, float("nan"))
        with self.assertRaises(ContractError):
            validate({"type":"string", "format":"uuid"}, "not-a-uuid")

    def test_result_contract_rejects_false_success(self):
        response = result()
        response["error"] = {"code":"bad","message":"bad","retryable":False}
        with self.assertRaises(ContractError):
            validate(load_schema("result.schema.json"), response)


class TimingTests(unittest.TestCase):
    def test_ntsc_and_long_duration_mapping_remain_exact(self):
        rate = {"num":30000,"den":1001}
        time = {"num":100100,"den":3}
        self.assertEqual(frame_snap(time, rate), time)
        self.assertEqual(source_to_timeline({"num":3,"den":1}, {"num":1,"den":1},
                                           {"num":10,"den":1}, {"num":2,"den":1}), {"num":11,"den":1})

    def test_words_snap_outward_to_source_frame_grid(self):
        words = [{"id":"a","start":{"num":1,"den":100},"end":{"num":99,"den":100}}]
        self.assertEqual(snap_words(["a"],words,{"num":24,"den":1}),
                         {"start":{"num":0,"den":1},"end":{"num":1,"den":1}})

    def test_invalid_rational_and_unordered_words_fail(self):
        for value in ({"num":1,"den":0},{"num":True,"den":1}, 0.3):
            with self.assertRaises(ContractError): rational(value)
        with self.assertRaises(ContractError):
            snap_words(["word-2","word-1"],example_plan()["sources"][0]["words"],{"num":24,"den":1})


class ToolsetTests(unittest.TestCase):
    def load(self, mode):
        from tests.test_mcp_tool_annotations import load_server_module
        with patch.dict(os.environ, {"SPLICEKIT_TOOLSET":mode}), \
                patch.object(socket.socket, "connect", side_effect=ConnectionRefusedError("offline")):
            return load_server_module()

    def test_v4_exposes_exact_bootstrap_without_legacy_plugins_resources_or_prompts(self):
        module = self.load("v4")
        names = {tool["name"] for tool in module.mcp.tools}
        self.assertEqual(names,{"session_status","capability_search","capability_describe","state_read",
                                "operation_status","history_checkpoint","capability_invoke"})
        self.assertEqual(module.mcp.resources,[])
        self.assertEqual(module.mcp.prompts,[])
        self.assertIsNone(module.bridge.sock)
        self.assertIn("capability_search",module.mcp.instructions)

    def test_legacy_and_all_keep_the_original_tools(self):
        legacy = {tool["name"] for tool in self.load("legacy").mcp.tools}
        all_tools = {tool["name"] for tool in self.load("all").mcp.tools}
        self.assertGreater(len(legacy),200)
        self.assertIn("raw_call",legacy)
        self.assertNotIn("capability_invoke",legacy)
        self.assertEqual(len(all_tools-legacy),7)
        self.assertTrue(legacy.issubset(all_tools))

    def test_invalid_mode_fails_early(self):
        with self.assertRaisesRegex(ValueError,"SPLICEKIT_TOOLSET"):
            self.load("invalid")


if __name__ == "__main__":
    unittest.main()
