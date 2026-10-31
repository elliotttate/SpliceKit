"""Keep Photos imports available through every FCP signing entry point."""

import plistlib
import re
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
PHOTOS_LIBRARY = "com.apple.security.personal-information.photos-library"


class PhotosLibraryEntitlementTests(unittest.TestCase):
    def test_all_signing_templates_allow_photos_library_access(self):
        # Both Swift patchers generate separate plists for patch and update.
        templates = {
            "entitlements.plist": 1,
            "patcher/patch_fcp.sh": 1,
            "patcher/SpliceKit/Models/PatcherModel.swift": 2,
            "patcher/SpliceKitPatcher/main.swift": 2,
        }
        for relative_path, expected_count in templates.items():
            source = (ROOT / relative_path).read_text(encoding="utf-8")
            plists = [
                xml
                for xml in re.findall(r"<\?xml.*?</plist>", source, flags=re.DOTALL)
                if "com.apple.security.app-sandbox" in xml
            ]
            with self.subTest(path=relative_path):
                self.assertEqual(len(plists), expected_count)
            for index, xml in enumerate(plists):
                with self.subTest(path=relative_path, template=index):
                    entitlements = plistlib.loads(xml.encode("utf-8"))
                    self.assertIs(entitlements.get(PHOTOS_LIBRARY), True)


if __name__ == "__main__":
    unittest.main()
