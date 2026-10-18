"""Compile production ObjC handlers against mocks and check their published contracts.

No host process, plugin loader, socket, media decoder, or external Python dependency.
The small validator covers the JSON Schema vocabulary used by this manifest.
"""
import json
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import unittest

ROOT=Path(__file__).resolve().parents[1]
MANIFEST=ROOT/'mcp/splicekit_v4/capabilities/params.json'


def valid(value, schema, root):
    if '$ref' in schema:
        target=root
        for key in schema['$ref'].split('/')[1:]: target=target[key]
        return valid(value,target,root)
    if 'anyOf' in schema and not any(valid(value,s,root) for s in schema['anyOf']):return False
    if 'oneOf' in schema and sum(valid(value,s,root) for s in schema['oneOf'])!=1:return False
    if 'allOf' in schema and not all(valid(value,s,root) for s in schema['allOf']):return False
    if 'if' in schema and valid(value,schema['if'],root):
        if not valid(value,schema.get('then',{}),root):return False
    if 'const' in schema and (type(value)!=type(schema['const']) or value!=schema['const']):return False
    if 'enum' in schema and value not in schema['enum']:return False
    types=schema.get('type');types=types if isinstance(types,list) else [types] if types else []
    def is_type(t):
        return {'object':isinstance(value,dict),'array':isinstance(value,list),'string':isinstance(value,str),
                'number':type(value) in (int,float),'integer':type(value) is int,'boolean':type(value) is bool,'null':value is None}[t]
    if types and not any(is_type(t) for t in types):return False
    if isinstance(value,dict):
        if not all(k in value for k in schema.get('required',[])):return False
        props=schema.get('properties',{})
        for k,v in value.items():
            if k in props:
                if not valid(v,props[k],root):return False
            elif schema.get('additionalProperties',True) is False:return False
            elif isinstance(schema.get('additionalProperties'),dict):
                if not valid(v,schema['additionalProperties'],root):return False
    if isinstance(value,list) and 'items' in schema:
        if not all(valid(v,schema['items'],root) for v in value):return False
    if isinstance(value,str):
        if len(value)<schema.get('minLength',0):return False
        if 'pattern' in schema and re.search(schema['pattern'],value) is None:return False
    if type(value) in (int,float):
        if 'minimum' in schema and value<schema['minimum']:return False
        if 'maximum' in schema and value>schema['maximum']:return False
    return True


class ParamsContractTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.manifest=json.loads(MANIFEST.read_text())
        cls.methods={row['name']:row for row in cls.manifest['capabilities']}

    def test_catalog_contains_all_native_operations(self):
        self.assertEqual(len(self.methods),13)
        self.assertIn('v4.parameter.describe',self.methods)
        for row in self.methods.values():
            self.assertEqual(row['evidence_level'],'offline_tested')
            self.assertTrue(row['readback_supported'])
            self.assertEqual(set(row['output_schema']['required']), {'ok','operation_id','applied','readback','revision_before','revision_after','undo','evidence_level','warnings','error'})

    def test_input_schema_rejects_lossy_or_ambiguous_requests(self):
        row=self.methods['v4.keyframe.set'];schema=row['input_schema']
        good={'operation_id':'test-write','expected_revision':'r0','target':{'clip_id':'persisted-clip','effect_instance_id':'instance'},'parameter_path':'/effects/instance/channels/9999/100',
              'time':{'value':1001,'timescale':30000,'space':'clip_local'},'value':{'type':'double','value':0.3}}
        self.assertTrue(valid(good,schema,schema))
        for update in [dict(time={'value':0,'timescale':0,'space':'clip_local'}),dict(time={'value':0.3,'timescale':600,'space':'timeline'}),
                       dict(target={'handle':'obj_1'}),dict(parameter_path='Amount'),dict(value={'type':'double','value':True}),
                       dict(value={'type':'enum','value':'First'}),dict(time={'value':0,'timescale':1,'space':'source'})]:
            self.assertFalse(valid({**good,**update},schema,schema),update)
        self.assertFalse(valid({**good,'mode':'constant'},schema,schema))

    @unittest.skipUnless(sys.platform=='darwin','Native ObjC mock test requires macOS')
    def test_production_native_handlers_and_output_schemas(self):
        with tempfile.TemporaryDirectory(prefix='splicekit-params-') as directory:
            binary=Path(directory)/'params-native-tests'
            command=['clang','-fobjc-arc','-fmodules','-Werror','-DSPLICEKIT_V4_PARAMS_TEST=1','-mmacosx-version-min=14.0',
                     '-I',str(ROOT/'Sources'),'-framework','Foundation','-framework','CoreMedia',
                     *(str(ROOT/'Sources'/name) for name in ['SpliceKitV4Result.m','SpliceKitV4Effects.m','SpliceKitV4Parameters.m','SpliceKitV4Keyframes.m']),
                     str(ROOT/'tests/v4/params_native_tests.m'),'-o',str(binary)]
            build=subprocess.run(command,text=True,capture_output=True)
            self.assertEqual(build.returncode,0,build.stderr)
            run=subprocess.run([str(binary)],text=True,capture_output=True,timeout=30)
            self.assertEqual(run.returncode,0,run.stdout+run.stderr)
            results=[json.loads(line[7:]) for line in run.stdout.splitlines() if line.startswith('RESULT ')]
            self.assertGreaterEqual(len(results),40)
            seen=set()
            for result in results:
                method=result['undo']['label'];seen.add(method)
                schema=self.methods[method]['output_schema']
                self.assertTrue(valid(result,schema,schema),f'{method}: {result}')
            self.assertEqual(seen,set(self.methods))
            print(next(line for line in run.stdout.splitlines() if line.startswith('PASS:')))

    def test_every_rpc_has_a_live_case(self):
        plan=json.loads((ROOT/'tests/live/v4/params.json').read_text())
        covered={step['method'] for case in plan['manual_cases'] for step in case['steps'] if 'method' in step}
        self.assertTrue(set(self.methods).issubset(covered))
        for fixture in ['Gaussian','Letterbox','Colorize','transform_scale']:
            self.assertTrue(any(fixture in case['id'] for case in plan['manual_cases']),fixture)


if __name__=='__main__':unittest.main()
