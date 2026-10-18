"""Real loopback TCP acceptance, without Final Cut Pro or the production bridge."""
from copy import deepcopy
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

from tests.live.contract import VerificationError, assertions, digest, validate_plan
from tests.live.mock_rpc import MockBridge, mock_server
from tests.live.report import evidence_level, render
from tests.live.rpc import RPCClient
from tests.live.run_live import ROOT, promotion, run_plan, write_json, writer_lock


def sample(name="example-parameter-30"):
    return json.loads((ROOT / f"tests/live/v4/{name}.json").read_text(encoding="utf-8"))


class LiveRunnerTests(unittest.TestCase):
    def run_mock(self, bridge=None, plan=None, mode="mock"):
        bridge = bridge or MockBridge()
        with mock_server(bridge) as port:
            proof = run_plan(plan or sample(), RPCClient(port=port, timeout=2), bridge.library_path, mode)
        return bridge, proof

    def test_read_and_rejection_steps_never_undo_or_promote(self):
        class ObservationBridge(MockBridge):
            def dispatch(self, method, params):
                if method in {'v4.test.read', 'v4.test.reject'}:
                    self.calls.append((method, params))
                    rejected = method.endswith('reject')
                    return self.envelope('observation', self.revision, ok=not rejected,
                        applied=False, undo={'kind': 'none', 'label': ''},
                        error={'code': 'REVISION_MISMATCH', 'message': 'Stale', 'retryable': False} if rejected else None)
                return super().dispatch(method, params)
        for kind in ('read', 'rejection'):
            plan = sample()
            step = plan['steps'][0]
            step['kind'] = kind
            step.pop('undo')
            step['apply'] = {'method': 'v4.test.read' if kind == 'read' else 'v4.test.reject',
                             'params': {}, 'expect': {'/ok': kind == 'read', '/applied': False}}
            step['readback']['expect'] = {'/state': {'$ref': '/baseline/state'}}
            bridge, proof = self.run_mock(ObservationBridge(), plan)
            self.assertEqual(proof['status'], 'passed', proof.get('error'))
            self.assertEqual(bridge.mutations, 0)
            self.assertEqual(evidence_level(proof), 'offline_tested')
            self.assertIsNone(proof['steps'][0]['undo'])

    def test_post_apply_assertion_failure_still_undoes_settled_owned_edit(self):
        plan = sample()
        plan['steps'][0]['after_apply'] = [{'method': 'v4.parameter.inspect', 'params': {},
                                          'expect': {'/state/opacity': 0.75}}]
        bridge, proof = self.run_mock(plan=plan)
        self.assertEqual(proof['status'], 'failed')
        self.assertEqual(bridge.state['opacity'], 1)
        self.assertTrue(any(method == 'v4.operation.undo' for method, _ in bridge.calls))

    def test_settled_domain_error_still_reads_and_restores_owned_edit(self):
        class DomainFailure(MockBridge):
            def dispatch(self, method, params):
                result = super().dispatch(method, params)
                if method == 'v4.parameter.set':
                    result.update(ok=False, error={'code':'READBACK_MISMATCH', 'message':'No key', 'retryable':False})
                return result
        bridge, proof = self.run_mock(DomainFailure())
        self.assertEqual(proof['status'], 'failed')
        self.assertEqual(bridge.state['opacity'], 1)
        self.assertIn('after', proof['steps'][0])
        self.assertIn('restored', proof['steps'][0])
        self.assertEqual(proof['steps'][0]['baseline_sha256'], proof['steps'][0]['restored_sha256'])

    def test_full_tcp_cycle_and_raw_evidence(self):
        bridge, proof = self.run_mock()
        self.assertEqual(proof["status"], "passed", proof.get("error"))
        self.assertEqual(bridge.mutations, 1)
        self.assertEqual(bridge.state["opacity"], 1)
        self.assertEqual(evidence_level(proof), "offline_tested")
        self.assertEqual(proof["gates"]["host_readback"], "simulated")
        self.assertEqual(proof["gates"]["perceptual"], "not_checked")
        self.assertEqual(proof["gates"]["save_reopen"], "not_checked")
        step = proof["steps"][0]
        self.assertEqual(step["baseline_sha256"], step["restored_sha256"])
        self.assertNotEqual(step["baseline"], step["after"])
        self.assertTrue(any(call.get("ignored_frames") for call in proof["rpc_transcript"]))
        self.assertIsNone(promotion(proof, Path("unused.json")))

    def test_volatile_baseline_blocks_before_apply_without_undo(self):
        class VolatileObserver(MockBridge):
            observations = 0

            def dispatch(self, method, params):
                result = super().dispatch(method, params)
                if method == "v4.parameter.inspect":
                    self.observations += 1
                    result["state"]["bookmark"] = str(self.observations)
                return result

        bridge, proof = self.run_mock(VolatileObserver())
        self.assertEqual(proof["status"], "failed")
        self.assertIn("baseline is unstable before apply", proof["error"]["message"])
        self.assertEqual(bridge.mutations, 0)
        self.assertFalse(any(name in {"v4.parameter.set", "v4.operation.undo"} for name, _ in bridge.calls))
        self.assertIn("baseline_confirmation", proof["steps"][0])
        self.assertNotEqual(proof["steps"][0]["baseline_sha256"],
                            proof["steps"][0]["baseline_confirmation_sha256"])

    def test_report_rejects_tampered_preapply_confirmation(self):
        _, proof = self.run_mock()
        proof["steps"][0]["baseline_confirmation"]["state"]["opacity"] = 0.75
        with self.assertRaisesRegex(VerificationError, "Unstable pre-apply baseline"):
            evidence_level(proof)

    def test_fractional_rate_plan(self):
        _, proof = self.run_mock(MockBridge("SpliceKit-Test-2997", "1001/30000s"), sample("example-trim-2997"))
        self.assertEqual(proof["status"], "passed", proof.get("error"))
        self.assertEqual(proof["steps"][0]["after"]["state"]["duration"], "89089/30000s")

    def test_blocked_admission_never_claims_native_analysis_or_sends_undo(self):
        bridge, proof = self.run_mock(plan=sample("example-admission-30"))
        self.assertEqual(proof["status"], "passed", proof.get("error"))
        self.assertEqual(bridge.mutations, 0)
        self.assertEqual(proof["evidence_level"], "offline_tested")
        self.assertEqual(evidence_level(proof), "offline_tested")
        self.assertEqual(proof["gates"]["native_undo_restore"], "not_checked")
        self.assertFalse(any(name == "v4.operation.undo" for name, _ in bridge.calls))
        self.assertIsNone(promotion(proof, Path("unused.json")))

    def test_admission_flags_cannot_be_omitted(self):
        plan = sample("example-admission-30")
        del plan["steps"][0]["apply"]["expect"]["/readback/native_started"]
        with self.assertRaisesRegex(VerificationError, "native_started"):
            validate_plan(plan)

    def test_core_revision_after_observation_pointer(self):
        plan = sample()
        plan["steps"][0]["readback"]["revision"] = "/revision_after"
        plan["steps"][0]["apply"]["params"]["expected_revision"] = {"$ref": "/baseline/revision_after"}
        _, proof = self.run_mock(plan=plan)
        self.assertEqual(proof["status"], "passed", proof.get("error"))

    def test_mixed_plan_only_promotes_mutations_in_synthetic_live_candidate(self):
        plan = sample()
        plan["steps"].extend(sample("example-admission-30")["steps"])
        _, proof = self.run_mock(plan=plan)
        self.assertEqual(proof["status"], "passed", proof.get("error"))
        proof["plan"].pop("template")
        proof["plan_sha256"] = digest(proof["plan"])
        proof["mode"] = "live"
        proof["runtime"] = {"fcp_build": "synthetic-build-for-unit-test", "fcp_version": "12.4",
                            "splicekit_version": "4-test", "arch": "arm64", "macos_version": "14-test"}
        proof["gates"]["host_readback"] = "passed"
        proof["gates"]["native_undo_restore"] = "passed"
        proof["evidence_level"] = "live_verified"
        candidate = promotion(proof, Path("synthetic-only.json"))
        self.assertEqual(candidate["capabilities"], [{"name": "v4.parameter.set", "evidence_level": "live_verified"}])
        self.assertEqual(candidate["blocked_admissions"], ["v4.media.analyze"])

    def test_zero_or_multiple_libraries_block_before_any_mutation(self):
        for count in (0, 2):
            with self.subTest(count=count):
                bridge = MockBridge()
                bridge.library_count = count
                _, proof = self.run_mock(bridge)
                self.assertEqual(proof["status"], "failed")
                self.assertEqual(bridge.mutations, 0)
                self.assertFalse(any(name.startswith("v4.") for name, _ in bridge.calls))

    def test_production_library_is_never_touched(self):
        bridge = MockBridge()
        bridge.library_name = "Production"
        _, proof = self.run_mock(bridge)
        self.assertEqual(proof["status"], "failed")
        self.assertEqual(bridge.mutations, 0)
        self.assertFalse(any(name.startswith("v4.") for name, _ in bridge.calls))

    def test_path_mismatch_blocks_despite_safe_display_name(self):
        bridge = MockBridge()
        with mock_server(bridge) as port:
            proof = run_plan(sample(), RPCClient(port=port), "/tmp/SpliceKit-Test-other.fcpbundle", "mock")
        self.assertEqual(proof["status"], "failed")
        self.assertEqual(bridge.mutations, 0)

    def test_wrong_project_or_rate_blocks(self):
        for bridge in (MockBridge(project="Production project"), MockBridge(frame_duration="1001/30000s")):
            _, proof = self.run_mock(bridge)
            self.assertEqual(proof["status"], "failed")
            self.assertEqual(bridge.mutations, 0)

    def test_disconnect_after_apply_is_unknown_without_undo_or_replay(self):
        bridge, proof = self.run_mock(MockBridge(fault="disconnect"))
        self.assertEqual(proof["status"], "unknown")
        self.assertEqual(bridge.mutations, 1)
        self.assertFalse(any(name == "v4.operation.undo" for name, _ in bridge.calls))
        self.assertEqual(bridge.state["opacity"], 0.5)

    def test_host_unknown_does_not_trigger_undo(self):
        bridge, proof = self.run_mock(MockBridge(fault="unknown"))
        self.assertEqual(proof["status"], "unknown")
        self.assertFalse(any(name == "v4.operation.undo" for name, _ in bridge.calls))

    def test_actual_socket_timeout_after_mutation_is_not_replayed(self):
        bridge = MockBridge(fault="timeout")
        with mock_server(bridge) as port:
            proof = run_plan(sample(), RPCClient(port=port, timeout=0.05), bridge.library_path, "mock")
        self.assertEqual(proof["status"], "unknown", proof.get("error"))
        self.assertEqual(bridge.mutations, 1)
        self.assertFalse(any(name == "v4.operation.undo" for name, _ in bridge.calls))

    def test_revision_drift_stops_before_undo(self):
        bridge, proof = self.run_mock(MockBridge(fault="revision_drift"))
        self.assertEqual(proof["status"], "unknown")
        self.assertFalse(any(name == "v4.operation.undo" for name, _ in bridge.calls))

    def test_embedded_readback_cannot_hide_failed_mutation(self):
        bridge, proof = self.run_mock(MockBridge(fault="lie"))
        self.assertEqual(proof["status"], "failed")
        self.assertEqual(bridge.state["opacity"], 1)
        self.assertIn("Readback mismatch", proof["error"]["message"])

    def test_noop_cannot_produce_evidence(self):
        plan = sample()
        plan["steps"][0]["apply"]["params"]["value"] = 1.0
        plan["steps"][0]["readback"]["expect"]["/state/opacity"] = 1.0
        _, proof = self.run_mock(MockBridge(fault="no_change"), plan)
        self.assertEqual(proof["status"], "failed")
        self.assertIn("no independently observed", proof["error"]["message"])

    def test_undo_damage_outside_changed_leaf_is_detected(self):
        _, proof = self.run_mock(MockBridge(fault="dirty_undo"))
        self.assertEqual(proof["status"], "failed")
        self.assertIn("did not restore", proof["error"]["message"])

    def test_invalid_envelope_does_not_trigger_generic_undo(self):
        bridge, proof = self.run_mock(MockBridge(fault="bad_envelope"))
        self.assertEqual(proof["status"], "failed")
        self.assertFalse(any(name == "v4.operation.undo" for name, _ in bridge.calls))

    def test_new_library_opened_between_apply_and_undo_blocks_undo(self):
        class Intruded(MockBridge):
            def dispatch(self, method, params):
                result = super().dispatch(method, params)
                if method == "v4.parameter.set":
                    self.library_count = 2
                return result
        bridge, proof = self.run_mock(Intruded())
        self.assertEqual(proof["status"], "failed")
        self.assertEqual(bridge.mutations, 1)
        self.assertFalse(any(name == "v4.operation.undo" for name, _ in bridge.calls))

    def test_simulated_runtime_cannot_be_live_verified(self):
        plan = sample()
        plan.pop("template")
        bridge, proof = self.run_mock(plan=plan, mode="live")
        self.assertEqual(proof["status"], "failed")
        self.assertEqual(bridge.mutations, 0)
        self.assertIsNone(promotion(proof, Path("unused.json")))

    def test_templates_are_rejected_in_live_mode_before_rpc(self):
        rpc = RPCClient(port=1)
        with self.assertRaisesRegex(VerificationError, "Template"):
            run_plan(sample(), rpc, "/tmp/SpliceKit-Test-v4.fcpbundle", "live")
        self.assertEqual(rpc.transcript, [])

    def test_cli_end_to_end_preserves_evidence_and_never_promotes_mock(self):
        bridge = MockBridge()
        with tempfile.TemporaryDirectory() as directory, mock_server(bridge) as port:
            command = [sys.executable, "-m", "tests.live.run_live", "--mock",
                       str(ROOT / "tests/live/v4/example-parameter-30.json"),
                       "--port", str(port), "--library-path", bridge.library_path,
                       "--evidence-dir", directory]
            for _ in range(2):
                result = subprocess.run(command, cwd=ROOT, capture_output=True, text=True, timeout=30)
                self.assertEqual(result.returncode, 0, result.stderr + result.stdout)
            files = list(Path(directory).glob("*/*.json"))
            self.assertEqual(len(files), 2)
            self.assertFalse(list(Path(directory).rglob("*.promotion.json")))
            proof = json.loads(files[0].read_text())
            self.assertEqual(proof["status"], "passed")
            self.assertIn("offline_tested", render(directory, Path(directory) / "registry"))

    def test_cli_quarantine_blocks_replay_after_unknown(self):
        bridge = MockBridge(fault="disconnect")
        with tempfile.TemporaryDirectory() as directory, mock_server(bridge) as port:
            command = [sys.executable, "-m", "tests.live.run_live", "--mock",
                       str(ROOT / "tests/live/v4/example-parameter-30.json"),
                       "--port", str(port), "--library-path", bridge.library_path,
                       "--evidence-dir", directory]
            first = subprocess.run(command, cwd=ROOT, capture_output=True, text=True, timeout=30)
            second = subprocess.run(command, cwd=ROOT, capture_output=True, text=True, timeout=30)
            self.assertEqual(first.returncode, 1, first.stderr)
            self.assertEqual(second.returncode, 2, second.stderr)
            self.assertIn("reconciliation", second.stderr)
            self.assertEqual(bridge.mutations, 1)
            self.assertTrue(list(Path(directory).glob(".quarantine-*.json")))

    def test_reporting_rejects_tampered_restore_and_promoted_mock(self):
        _, proof = self.run_mock()
        tampered = deepcopy(proof)
        tampered["steps"][0]["restored"]["state"]["unrelated_clip"]["gain_db"] = -4
        with self.assertRaises(VerificationError):
            evidence_level(tampered)
        tampered = deepcopy(proof)
        tampered["mode"] = "live"
        tampered["evidence_level"] = "live_verified"
        with self.assertRaises(VerificationError):
            evidence_level(tampered)

    def test_promotion_candidate_binds_a_synthetic_live_proof_to_its_hash_and_build(self):
        # Exercise the serialization branch with a synthetic document, not a live claim.
        _, proof = self.run_mock()
        proof["plan"].pop("template")
        proof["plan_sha256"] = digest(proof["plan"])
        proof["mode"] = "live"
        proof["runtime"] = {"fcp_version": "12.4", "fcp_build": "synthetic-build-for-unit-test",
                            "splicekit_version": "4-test", "arch": "arm64", "macos_version": "14-test"}
        proof["gates"]["host_readback"] = "passed"
        proof["gates"]["native_undo_restore"] = "passed"
        proof["evidence_level"] = "live_verified"
        candidate = promotion(proof, Path("synthetic-only.json"))
        self.assertEqual(candidate["fcp_build"], "synthetic-build-for-unit-test")
        self.assertEqual(candidate["evidence_sha256"], digest(proof))
        self.assertEqual(candidate["scope"], ["host_readback", "native_undo_restore"])

    def test_report_does_not_trust_declared_success_when_after_is_wrong(self):
        _, proof = self.run_mock()
        proof["steps"][0]["after"]["state"]["opacity"] = 0.7
        with self.assertRaises(VerificationError):
            evidence_level(proof)

    def test_no_clobber_evidence_and_endpoint_wide_lock(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "proof.json"
            write_json(path, {"first": True})
            with self.assertRaises(FileExistsError):
                write_json(path, {"first": False})
            self.assertEqual(json.loads(path.read_text()), {"first": True})
        with mock_server(MockBridge()) as port:
            with writer_lock(port):
                with self.assertRaisesRegex(VerificationError, "Another live runner"):
                    with writer_lock(port):
                        self.fail("Concurrent writer was admitted")

    def test_schema_requires_owned_undo_and_nonempty_state_comparison(self):
        for mutate in (
            lambda p: p["steps"][0]["undo"].update(method="timeline.action"),
            lambda p: p["steps"][0]["undo"]["params"].update(operation_id="unowned"),
            lambda p: p["steps"][0]["readback"].update(compare=[]),
            lambda p: p["steps"][0]["readback"].update(compare=["/other"]),
            lambda p: p.update(id="../escape"),
        ):
            plan = sample()
            mutate(plan)
            with self.assertRaises(VerificationError):
                validate_plan(plan)

    def test_json_comparison_preserves_boolean_number_distinction(self):
        self.assertNotEqual(digest(False), digest(0))
        with self.assertRaises(VerificationError):
            assertions({"linked": 1}, {"/linked": True})


if __name__ == "__main__":
    unittest.main()
