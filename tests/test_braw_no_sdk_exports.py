"""The optional BRAW SDK must not leave mandatory bridge symbols unresolved."""
import platform
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SDK_HEADER = Path('/Applications/Blackmagic RAW/Blackmagic RAW SDK/Mac/Include/BlackmagicRawAPI.h')


@unittest.skipUnless(platform.system() == 'Darwin' and not SDK_HEADER.exists(),
                     'macOS no-SDK fallback test')
class BRAWNoSDKExports(unittest.TestCase):
    def test_no_sdk_exports_on_both_supported_architectures(self):
        (ROOT / 'build').mkdir(exist_ok=True)
        with tempfile.TemporaryDirectory(dir=ROOT / 'build') as directory:
            output = Path(directory) / 'fallback.o'
            subprocess.run(['clang', '-arch', 'arm64', '-arch', 'x86_64',
                            '-fobjc-arc', '-fmodules', '-std=c++17', '-c',
                            str(ROOT / 'Sources/SpliceKitBRAW.mm'),
                            '-o', str(output)], check=True, capture_output=True, text=True)
            for arch in ('arm64', 'x86_64'):
                symbols = subprocess.check_output(['nm', '-arch', arch, '-gU', str(output)], text=True)
                self.assertIn(' T _SpliceKit_bootstrapBRAWAtLaunchPhase', symbols)
                self.assertIn(' T _SpliceKit_handleBRAWAVProbe', symbols)


if __name__ == '__main__':
    unittest.main()
