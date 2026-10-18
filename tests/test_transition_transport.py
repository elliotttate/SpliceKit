"""Regression coverage for the MCP transition boolean transport (no FCP required)."""
import ast
from pathlib import Path
from types import SimpleNamespace
import unittest


class TransitionTransportTests(unittest.TestCase):
    def test_freeze_extend_is_always_explicit(self):
        source = Path(__file__).resolve().parents[1] / "mcp" / "server.py"
        tree = ast.parse(source.read_text())
        function = next(n for n in tree.body if isinstance(n, ast.FunctionDef)
                        and n.name == "apply_transition")
        function.decorator_list = []
        calls = []
        def call(method, **params):
            calls.append((method, params))
            return {"transition": "Cross Dissolve", "effectID": "dissolve"}
        namespace = {"bridge": SimpleNamespace(call=call), "_err": lambda r: False}
        exec(compile(ast.Module(body=[function], type_ignores=[]), str(source), "exec"), namespace)
        for value in (False, True):
            namespace["apply_transition"](effectID="dissolve", freeze_extend=value)
            self.assertEqual(calls[-1], ("transitions.apply", {
                "effectID": "dissolve", "freezeExtend": value}))
        namespace["apply_transition"](name="Cross Dissolve")
        self.assertIs(calls[-1][1]["freezeExtend"], True)


if __name__ == "__main__":
    unittest.main()
