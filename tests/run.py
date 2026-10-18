"""Run the FCP-free unittest suite: python3 -m tests.run."""
import argparse
import os
import socket
import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
# These are legacy executable integration scripts, not offline unittest suites.
LIVE_SCRIPTS = {"test_ai_command.py", "test_mcp_endpoints.py"}


class OfflineSocket(socket.socket):
    """Allow loopback test servers while excluding FCP and external services."""
    @staticmethod
    def allowed(address):
        return (isinstance(address, tuple) and address[0] in {"127.0.0.1", "::1", "localhost"}
                and address[1] != 9876)

    def connect(self, address):
        if not self.allowed(address):
            self.close()
            raise ConnectionRefusedError("Offline suite: production/native/network connection disabled")
        return super().connect(address)

    def connect_ex(self, address):
        if not self.allowed(address):
            return 61  # ECONNREFUSED on macOS
        return super().connect_ex(address)


def suite():
    loader = unittest.TestLoader()
    result = unittest.TestSuite()
    for path in sorted((ROOT / "tests").rglob("test_*.py")):
        if path.name in LIVE_SCRIPTS:
            continue
        name = ".".join(path.relative_to(ROOT).with_suffix("").parts)
        result.addTests(loader.loadTestsFromName(name))
    return result


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("-v", "--verbose", action="store_true")
    args = parser.parse_args(argv)
    sys.dont_write_bytecode = True
    socket.socket = OfflineSocket
    manifest = ROOT / "build/otio-fixture-adapter/src/otio_fcpxml_adapter/plugin_manifest.json"
    if manifest.is_file():
        os.environ.setdefault("OTIO_PLUGIN_MANIFEST_PATH", str(manifest))
        os.environ.setdefault("OTIO_DISABLE_ENTRYPOINTS_PLUGINS", "1")
    print("Offline suite: legacy FCP/Apple Intelligence integration scripts excluded.", flush=True)
    result = unittest.TextTestRunner(verbosity=2 if args.verbose else 1).run(suite())
    return 0 if result.wasSuccessful() else 1


if __name__ == "__main__":
    raise SystemExit(main())
