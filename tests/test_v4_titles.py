"""Native text/transition contracts and JSON manifests, without starting Final Cut."""
import json
import os
import platform
import subprocess
import tempfile
import unittest
from pathlib import Path

try:
    from jsonschema import Draft202012Validator
except ImportError:
    Draft202012Validator = None

ROOT = Path(__file__).resolve().parents[1]
CAPABILITIES = ROOT / 'mcp/splicekit_v4/capabilities/titles.json'
LIVE_PLAN = ROOT / 'tests/live/v4/titles.json'
SOURCES = ['SpliceKitV4Result.m', 'SpliceKitV4TitlesSupport.m', 'SpliceKitV4TitleStyles.m',
           'SpliceKitV4Titles.m', 'SpliceKitV4Captions.m', 'SpliceKitV4Transitions.m']


class TitlesManifestTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.items = json.loads(CAPABILITIES.read_text())['capabilities']

    def test_complete_native_capability_metadata(self):
        self.assertEqual(len(self.items), 11)
        self.assertEqual(len({item['name'] for item in self.items}), 11)
        for item in self.items:
            self.assertEqual(item['method'], item['name'])
            self.assertEqual(item['backend'], 'native')
            self.assertTrue(item['readback_supported'])
            self.assertEqual(item['evidence_level'], 'offline_tested')
            self.assertEqual(item['requires_fcp_build'], ['454072'])
            self.assertIn(item['undo_kind'], ('none', 'native_group'))
            self.assertTrue(item['known_limitations'])
            self.assertFalse(item['input_schema']['additionalProperties'])

    @unittest.skipIf(Draft202012Validator is None, 'install jsonschema for full schema validation')
    def test_standalone_json_schemas(self):
        for item in self.items:
            Draft202012Validator.check_schema(item['input_schema'])
            Draft202012Validator.check_schema(item['output_schema'])
        from tests.live.contract import validate_plan, resolve
        plan = validate_plan(json.loads(LIVE_PLAN.read_text()))
        for step in plan['steps']:
            params = resolve(step['apply']['params'], {'fixture': plan['fixture'],
                'run': {'operation_id': 'test-write'}, 'baseline': {'revision_after': 'r0'}})
            descriptor = next(item for item in self.items if item['method'] == step['apply']['method'])
            Draft202012Validator(descriptor['input_schema']).validate(params)

    @unittest.skipIf(Draft202012Validator is None, 'install jsonschema for full schema validation')
    def test_negative_argument_schemas(self):
        by_name = {item['name']: item for item in self.items}
        cases = [
            ('v4.title.insert', {'effectID': 'title', 'lane': 0, 'start': {'value': 0, 'timescale': 24}, 'duration': {'value': 24, 'timescale': 24}}),
            ('v4.title.set_text', {'clip_id': 'id', 'text': 'ambiguous field'}),
            ('v4.title.set_style', {'clip_id': 'id', 'field_index': 0, 'spans': []}),
            ('v4.caption.set_text', {'clip_id': 'id', 'text': 'ambiguous block'}),
            ('v4.transition.set', {'cut': {'left_clip_id': 'a', 'right_clip_id': 'b'}, 'effectID': 'dissolve', 'duration': {'value': 24, 'timescale': 24}}),
            ('v4.caption.set_timing', {'clip_id': 'id', 'start': {'value': True, 'timescale': 24}, 'duration': {'value': 0, 'timescale': 24}}),
        ]
        for name, params in cases:
            self.assertFalse(Draft202012Validator(by_name[name]['input_schema']).is_valid(params), name)


@unittest.skipUnless(platform.system() == 'Darwin', 'Objective-C/AppKit mock executable requires macOS')
class NativeTitlesMockTests(unittest.TestCase):
    def test_native_handlers_and_recorded_outputs(self):
        (ROOT / 'build').mkdir(exist_ok=True)
        with tempfile.TemporaryDirectory(prefix='titles-test-', dir=ROOT / 'build') as directory:
            directory = Path(directory)
            binary, records_path = directory / 'mock', directory / 'records.jsonl'
            command = ['clang', '-fobjc-arc', '-fblocks', '-fmodules',
                       '-DSKT_MAIN_WAIT_NS=100000000', '-I', str(ROOT / 'Sources')]
            command += [str(ROOT / 'Sources' / source) for source in SOURCES]
            command += [str(ROOT / 'tests/native/v4/titles_mock.m'), '-framework', 'Foundation',
                        '-framework', 'AppKit', '-framework', 'CoreMedia', '-o', str(binary)]
            built = subprocess.run(command, text=True, capture_output=True, timeout=90)
            self.assertEqual(built.returncode, 0, built.stderr)
            env = {**os.environ, 'SKT_MOCK_RESULTS_PATH': str(records_path)}
            result = subprocess.run([str(binary)], text=True, capture_output=True, env=env, timeout=30)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn('PASS:', result.stdout)
            records = [json.loads(line) for line in records_path.read_text().splitlines()]
            capabilities = {item['name']: item for item in json.loads(CAPABILITIES.read_text())['capabilities']}
            self.assertEqual({record['method'] for record in records}, capabilities.keys())
            if Draft202012Validator:
                for record in records:
                    with self.subTest(method=record['method'], error=record['result']['error']):
                        Draft202012Validator(capabilities[record['method']]['output_schema']).validate(record['result'])
            print(result.stdout.strip())


if __name__ == '__main__':
    unittest.main()
