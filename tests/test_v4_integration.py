"""Compile the actual native registry and compare it with shipped descriptors."""
import json
import platform
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'mcp'))
from splicekit_v4.registry import CapabilityRegistry, validate
from splicekit_v4.envelope import RESULT_SCHEMA


class IntegrationTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.registry = CapabilityRegistry()

    def test_one_shared_python_result_schema(self):
        schema = json.loads((ROOT / 'mcp/splicekit_v4/schemas/result.schema.json').read_text())
        self.assertEqual(schema, RESULT_SCHEMA)

    @unittest.skipUnless(platform.system() == 'Darwin', 'Native registration requires macOS clang')
    def test_native_registry_descriptor_bijection_and_mutation_contract(self):
        with tempfile.TemporaryDirectory(prefix='sk4-registry-') as temp:
            binary = Path(temp) / 'registry'
            sources = sorted((ROOT / 'Sources').glob('SpliceKitV4*.m'))
            command = ['clang', '-fobjc-arc', '-fmodules', '-DSPLICEKIT_V4_TESTING',
                       '-I', str(ROOT / 'Sources'), '-framework', 'Foundation',
                       '-framework', 'AppKit', '-framework', 'CoreMedia',
                       *map(str, sources), str(ROOT / 'tests/v4_registry_offline.m'), '-o', str(binary)]
            compiled = subprocess.run(command, capture_output=True, text=True, timeout=60)
            self.assertEqual(compiled.returncode, 0, compiled.stderr)
            run = subprocess.run([str(binary), str(Path(temp) / 'ledger/operations.jsonl')],
                                 capture_output=True, text=True, timeout=10)
            self.assertEqual(run.returncode, 0, run.stderr)
            native = json.loads(run.stdout)
        descriptors = {cap['method']: cap for cap in self.registry._items.values() if cap.get('method')}
        self.assertEqual(native.keys(), descriptors.keys())
        self.assertEqual(len(native), 49)
        for method, meta in native.items():
            cap = descriptors[method]
            with self.subTest(method=method):
                self.assertEqual(cap['name'], method)
                mutation = not meta.get('readOnly', False)
                self.assertEqual(mutation, cap['operation_kind'] != 'read')
                if mutation:
                    self.assertTrue({'operation_id', 'expected_revision'}.issubset(cap['input_schema']['required']))
                    self.assertEqual(meta.get('v4Undo', 'native_group'), cap['undo_kind'])
                    if method not in {'v4.history.undo', 'v4.analysis.start', 'v4.analysis.cancel'}:
                        self.assertEqual(cap['undo_kind'], 'native_group')
                self.assertEqual(cap['requires_fcp_build'], ['454072'])
                self.assertEqual(cap['evidence_level'], 'offline_tested')

    def test_all_native_capabilities_are_discoverable_and_schema_checked(self):
        native = [cap for cap in self.registry._items.values() if cap.get('method')]
        self.assertEqual(len(native), 49)
        for cap in native:
            found = self.registry.search(cap['name'], limit=50)
            self.assertIn(cap['name'], [item['name'] for item in found['matches']])
            if cap['operation_kind'] == 'mutation':
                for field in ('operation_id', 'expected_revision'):
                    self.assertIn(field, cap['input_schema']['required'])

    def test_ordered_live_suite_uses_registered_schema_valid_native_calls(self):
        from tests.live.contract import validate_plan, resolve
        suite = json.loads((ROOT / 'tests/live/v4-suite.json').read_text())
        self.assertEqual(suite['plans'], ['agent.json', 'core.json', 'params.json', 'titles.json', 'media.json'])
        count = 0
        for filename in suite['plans']:
            plan = validate_plan(json.loads((ROOT / 'tests/live/v4' / filename).read_text()))
            context = {'fixture': plan['fixture'], 'baseline': {'revision_after': 'r0'},
                       'run': {'operation_id': 'test-apply', 'check_operation_id': 'test-check'}}
            for step in plan['steps']:
                count += 1
                cap = self.registry.get(step['capability'])
                self.assertEqual(cap['method'], step['apply']['method'])
                args = resolve(step['apply']['params'], context)
                validate(cap['input_schema'], args)
                for call in [step['readback'], *step.get('after_apply', [])]:
                    self.registry.get(call['method'])
                if filename == 'agent.json':
                    self.assertEqual(step['kind'], 'read')
                elif step.get('kind', 'mutation') == 'mutation':
                    self.assertEqual(step['readback']['method'], 'v4.state.snapshot')
                    self.assertIn('/readback/state', step['readback']['compare'])
        self.assertEqual(count, 46)

    def test_native_pending_then_terminal_ledger_result_clears_unknown(self):
        from splicekit_v4.runtime import AgentRuntime
        from splicekit_v4.envelope import pending, result
        class Host:
            def call(self, method, **args):
                if method == 'system.version':
                    return {'fcp_build': '454072'}
                if method == 'v4.history.undo':
                    return pending(args['operation_id'])
                if method == 'v4.operation.status':
                    return result(operation_id=args['operation_id'], readback={
                        'state': 'COMPLETED', 'operation': {'session_id': 'native-ledger'},
                        'result': result(operation_id=args['operation_id'], applied=True,
                                         revision_before='r1', revision_after='r2', readback={'undone_operation_id': 'edit'})})
                raise AssertionError(method)
        runtime = AgentRuntime(Host())
        response = runtime.execute('v4.history.undo', {
            'operation_id': 'undo', 'target_operation_id': 'edit', 'expected_revision': 'r1'})
        self.assertEqual(response['status'], 'pending')
        self.assertIn('undo', runtime.unknown)
        runtime.operation_status('undo')
        self.assertNotIn('undo', runtime.unknown)
        self.assertEqual(runtime.operations['undo']['revision_after'], 'r2')

    def test_real_native_plan_arguments_use_descriptor_schema_and_nested_scope(self):
        from copy import deepcopy
        from splicekit_v4.runtime import AgentRuntime
        from splicekit_v4.contracts import ContractError
        runtime = AgentRuntime(None)
        plan = {'schema_version': 1, 'project_id': 'project', 'sequence_id': 'sequence',
                'base_revision': 'r0', 'frame_rate': {'num': 30, 'den': 1}, 'sources': [],
                'scope': {'target_ids': ['clip'], 'allow_ripple': False},
                'operations': [{'id': 'gain', 'kind': 'parameter', 'capability': 'v4.parameter.set',
                    'args': {'target': {'clip_id': 'clip'}, 'parameter_path': '/intrinsic/audio/channels/9999/1',
                             'time': {'value': 30, 'timescale': 30, 'space': 'clip_local'},
                             'mode': 'constant', 'value': {'type': 'double', 'value': 0.5}}}]}
        self.assertEqual(len(runtime.engine.validate(plan)['steps']), 1)
        outside = deepcopy(plan)
        outside['operations'][0]['args']['target']['clip_id'] = 'outside'
        with self.assertRaisesRegex(ContractError, 'outside|gain'):
            runtime.engine.validate(outside)
        with self.assertRaisesRegex(ContractError, 'history.restore'):
            runtime.engine.apply(plan, 'must-not-write')
        control = deepcopy(plan)
        control['operations'][0].update(capability='v4.history.undo', args={'target_operation_id': 'foreign'})
        with self.assertRaisesRegex(ContractError, 'family'):
            runtime.engine.validate(control)


if __name__ == '__main__':
    unittest.main()
