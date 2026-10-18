"""The no-SDK branch must define symbols called unconditionally by the bridge."""
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]

class OptionalBRAWExports(unittest.TestCase):
    @unittest.skipUnless(sys.platform == 'darwin', 'Objective-C++ compiler requires macOS')
    def test_no_sdk_link_exports(self):
        source = (ROOT/'Sources/SpliceKitBRAW.mm').read_text()
        fallback = source[source.index('\n#else\n\nSPLICEKIT_BRAW_EXTERN_C NSString *SpliceKitBRAWLookupPath'):source.rindex('\n#endif')]
        with tempfile.TemporaryDirectory() as temp:
            p = Path(temp)/'fallback.mm'
            p.write_text('#import <Foundation/Foundation.h>\n#import <CoreVideo/CoreVideo.h>\n#import <CoreMedia/CoreMedia.h>\n#define SPLICEKIT_BRAW_EXTERN_C extern "C"\n#if 0\n'+fallback+'\n#endif\n')
            output = Path(temp)/'fallback.o'
            subprocess.run(['clang++','-fobjc-arc','-fmodules','-c',str(p),'-o',str(output)],check=True,capture_output=True,text=True)
            symbols=subprocess.run(['nm','-g',str(output)],check=True,capture_output=True,text=True).stdout
            for name in ['SpliceKit_bootstrapBRAWAtLaunchPhase','SpliceKit_handleBRAWAVProbe','SpliceKitBRAWLookupPathForFormatDescription','SpliceKitBRAW_GetScaledDimensions']:
                self.assertIn(' T _'+name,symbols)
