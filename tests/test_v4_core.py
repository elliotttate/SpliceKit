"""Portable envelope checks plus the actual ObjC ledger/scheduler with a fake host.

No FCP application is launched or contacted. macOS/clang is needed only for the
native test; Python envelope/schema checks have no third-party dependencies.
"""
import importlib.util
import json
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("v4_envelope_under_test", ROOT / "mcp/splicekit_v4/envelope.py")
envelope = importlib.util.module_from_spec(spec)
spec.loader.exec_module(envelope)


class EnvelopeTests(unittest.TestCase):
    def test_success_contains_all_nulls_and_is_json_serializable(self):
        value = envelope.result(operation_id="read", readback={"count": 2})
        self.assertEqual(set(value), set(envelope.RESULT_SCHEMA["required"]))
        self.assertIsNone(json.loads(json.dumps(value))["error"])
        self.assertIsNone(value["revision_before"])
        self.assertIsNone(value["revision_after"])

    def test_unknown_does_not_claim_not_applied_or_allow_retry(self):
        value = envelope.failure("OUTCOME_UNKNOWN", "Reconcile", operation_id="one")
        self.assertIsNone(value["applied"])
        self.assertFalse(value["ok"])
        self.assertFalse(value["error"]["retryable"])
        self.assertEqual(value["undo"]["kind"], "unknown")

    def test_pending_is_accepted_and_has_unknown_application(self):
        value = envelope.pending("slow", state="RUNNING")
        self.assertTrue(value["ok"])
        self.assertIsNone(value["applied"])
        self.assertEqual(value["status"], "pending")
        self.assertEqual(value["operation_id"], "slow")

    def test_revision_rejection_is_explicitly_not_applied(self):
        value = envelope.failure("REVISION_MISMATCH", "Changed", applied=False,
                                 revision_before="old", revision_after="fresh")
        self.assertFalse(value["applied"])
        self.assertEqual(value["revision_after"], "fresh")

    def test_input_structures_are_not_aliased(self):
        source = {"clips": [1]}
        value = envelope.result(readback=source)
        source["clips"].append(2)
        self.assertEqual(value["readback"], {"clips": [1]})

    def test_invalid_schema_values_are_rejected(self):
        cases = [{"ok": 1}, {"applied": "unknown"}, {"undo_kind": "rollback"},
                 {"readback": []}, {"evidence_level": "production_enabled"},
                 {"warnings": "warning"}, {"revision_after": 2}, {"status": 1},
                 {"error": {"code": "X", "message": "X", "retryable": False}}]
        for case in cases:
            with self.subTest(case=case), self.assertRaises(ValueError):
                envelope.result(**case)

    def test_missing_keys_are_rejected(self):
        value = envelope.result()
        del value["error"]
        with self.assertRaises(ValueError):
            envelope.validate_envelope(value)

    def test_native_v4_route_precedes_legacy_side_effects_and_adapter(self):
        source = (ROOT / "Sources/SpliceKitServer.m").read_text()
        dispatcher = source[source.index("NSDictionary *SpliceKit_handleRequest("):]
        route = dispatcher.index('if ([method hasPrefix:@"v4."])')
        self.assertLess(route, dispatcher.index("SpliceKit_autoDismissBlockingDialogs();"))
        self.assertLess(route, dispatcher.index('BOOL wantsAsync ='))
        self.assertIn('@"result": SpliceKitV4Dispatch(method, params, handler, metadata)', dispatcher)
        self.assertIn('if (!SpliceKitV4IsExecuting()) SpliceKit_autoDismissBlockingDialogs();', dispatcher)

    def test_capabilities_use_shared_result_schema(self):
        capabilities = json.loads((ROOT / "mcp/splicekit_v4/capabilities/core.json").read_text())
        for capability in capabilities["capabilities"]:
            with self.subTest(name=capability["name"]):
                self.assertEqual(capability["output_schema"], envelope.RESULT_SCHEMA)
                self.assertEqual(capability["evidence_level"], "offline_tested")
        self.assertEqual(len(capabilities["capabilities"]), 7)


@unittest.skipUnless(sys.platform == "darwin" and shutil.which("clang"), "macOS clang is required")
class NativeCoreTests(unittest.TestCase):
    def test_actual_native_ledger_and_scheduler(self):
        build = ROOT / "build/v4-offline"
        build.mkdir(parents=True, exist_ok=True)
        with tempfile.TemporaryDirectory(prefix="suite-", dir=build) as temp:
            executable = Path(temp) / "core-tests"
            command = ["clang", "-fobjc-arc", "-fmodules", "-DSPLICEKIT_V4_TESTING",
                       "-I", str(ROOT / "Sources"), "-framework", "Foundation", "-framework", "AppKit"]
            command.extend(str(ROOT / item) for item in (
                "Sources/SpliceKitV4Result.m", "Sources/SpliceKitV4OperationLedger.m",
                "Sources/SpliceKitV4Core.m", "tests/v4_core_offline.m"))
            compiled = subprocess.run(command + ["-o", str(executable)], capture_output=True, text=True, timeout=60)
            self.assertEqual(compiled.returncode, 0, compiled.stderr)
            run = subprocess.run([str(executable), str(Path(temp) / "data")], capture_output=True, text=True, timeout=15)
            self.assertEqual(run.returncode, 0, run.stdout + run.stderr)
            self.assertIn("native offline checks passed", run.stdout)
            samples = json.loads((Path(temp) / "data/envelopes.json").read_text())
            for sample in samples:
                envelope.validate_envelope(sample)
            print(run.stdout.strip())


if __name__ == "__main__":
    unittest.main()
