"""Lossless legacy catalog output without importing MCP or contacting FCP."""
import ast
from pathlib import Path
import unittest

SERVER = Path(__file__).resolve().parents[1] / "mcp" / "server.py"


def load_formatter(name, response):
    tree = ast.parse(SERVER.read_text())
    fn = next(n for n in tree.body if isinstance(n, ast.FunctionDef) and n.name == name)
    fn.decorator_list = []
    class Bridge:
        def call(self, method, **params):
            return response
    namespace = {"bridge": Bridge(), "_err": lambda r: False}
    exec(compile(ast.Module(body=[fn], type_ignores=[]), str(SERVER), "exec"), namespace)
    return namespace[name]


class CatalogIdentityTests(unittest.TestCase):
    def test_effect_and_transition_ids_remain_copyable(self):
        prefix = ".../Effects.localized/" + "Very Long Category.localized/" * 8
        ids = [prefix + "Gaussian.moef", prefix + "Gaussian Distinct.moef"]
        rows = [{"name": "Same name", "category": "Blur", "type": "filter", "effectID": i} for i in ids]
        for name, key in [("list_effects", "effects"), ("list_transitions", "transitions")]:
            output = load_formatter(name, {key: rows})()
            for effect_id in ids:
                self.assertIn(effect_id, output)


if __name__ == "__main__":
    unittest.main()
