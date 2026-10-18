"""Ensure ObjC++ clients reference the C symbols implemented by ObjC units."""
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


@unittest.skipUnless(sys.platform == "darwin" and shutil.which("clang"), "macOS clang is required")
class CppAPILinkageTests(unittest.TestCase):
    def test_objcpp_uses_c_symbols_for_shared_runtime_api(self):
        build = ROOT / "build/v4-offline"
        build.mkdir(parents=True, exist_ok=True)
        with tempfile.TemporaryDirectory(prefix="cpp-abi-", dir=build) as temporary:
            obj = Path(temporary) / "client.o"
            source = '''#import "SpliceKit.h"
void Client(dispatch_block_t block) {
    SpliceKit_log(@"C API client");
    SpliceKit_executeOnMainThread(block);
}
'''
            compiled = subprocess.run(
                ["clang", "-x", "objective-c++", "-std=c++17", "-fobjc-arc",
                 "-I", str(ROOT / "Sources"), "-c", "-o", str(obj), "-"],
                input=source, capture_output=True, text=True, timeout=30)
            self.assertEqual(compiled.returncode, 0, compiled.stderr)
            undefined = subprocess.check_output(["nm", "-u", str(obj)], text=True)
            self.assertIn("_SpliceKit_log\n", undefined)
            self.assertIn("_SpliceKit_executeOnMainThread\n", undefined)
            self.assertFalse(any("SpliceKit" in line and "__Z" in line for line in undefined.splitlines()))


if __name__ == "__main__":
    unittest.main()
