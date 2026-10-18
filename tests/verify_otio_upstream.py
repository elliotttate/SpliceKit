"""Reproduce optional OTIO failures using untouched upstream server source.

python -m tests.verify_otio_upstream --upstream 223694a
Runs the current fixture assertions and dependencies. No FCP/network connection.
Exit status retains the test result; dependency skips are not verification.
"""
import argparse
import subprocess
import sys
import types
import unittest
from pathlib import Path

from tests import test_otio_upstream_fixtures as cases
from tests.run import OfflineSocket
import socket

ROOT = Path(__file__).resolve().parents[1]


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--upstream', default='223694a')
    args = parser.parse_args(argv)
    source = subprocess.check_output(['git', 'show', args.upstream + ':mcp/server.py'], cwd=ROOT, text=True)
    socket.socket = OfflineSocket

    def load():
        fastmcp = types.ModuleType('mcp.server.fastmcp')
        fastmcp.FastMCP = cases.FakeFastMCP
        injected = {'mcp': types.ModuleType('mcp'), 'mcp.server': types.ModuleType('mcp.server'),
                    'mcp.server.fastmcp': fastmcp}
        previous = {name: sys.modules.get(name) for name in injected}
        try:
            sys.modules.update(injected)
            module = types.ModuleType('untouched_upstream_server')
            module.__file__ = str(ROOT / 'mcp/server.py')
            exec(compile(source, args.upstream + ':mcp/server.py', 'exec'), module.__dict__)
            return module
        finally:
            for name, value in previous.items():
                if value is None:
                    sys.modules.pop(name, None)
                else:
                    sys.modules[name] = value

    cases.load_server_module = load
    print('Untouched upstream ' + args.upstream + '; current fixture assertions and identical dependencies.', flush=True)
    result = unittest.TextTestRunner(verbosity=2).run(unittest.defaultTestLoader.loadTestsFromTestCase(cases.OTIOUpstreamFixtureTests))
    return 2 if result.skipped else 0 if result.wasSuccessful() else 1


if __name__ == '__main__':
    raise SystemExit(main())
