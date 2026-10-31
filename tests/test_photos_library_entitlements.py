"""Keep Photos imports available through every FCP signing entry point."""

import plistlib
import re
import shutil
import subprocess
import sys
import tempfile
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

    def test_gui_diagnostics_only_check_configured_entitlements(self):
        source = (ROOT / "patcher/SpliceKit/Models/PatcherModel.swift").read_text()
        diagnostics = re.findall(r"let entKeys = \[([^\]]+)\]", source)
        self.assertEqual(len(diagnostics), 2)
        templates = [
            plistlib.loads(xml.encode("utf-8"))
            for xml in re.findall(r"<\?xml.*?</plist>", source, flags=re.DOTALL)
            if "com.apple.security.app-sandbox" in xml
        ]
        for index, diagnostic in enumerate(diagnostics):
            configured = {key.rsplit(".", 1)[-1] for key in templates[index]}
            for key in re.findall(r'"([^"]+)"', diagnostic):
                with self.subTest(template=index, key=key):
                    self.assertIn(key, configured)


@unittest.skipUnless(sys.platform == "darwin", "Installer verification uses macOS plist tools")
class SignedEntitlementVerificationTests(unittest.TestCase):
    def run_verification(self, payload, codesign_status=0, real_signature=False):
        source = (ROOT / "patcher/patch_fcp.sh").read_text(encoding="utf-8")
        block = source.split("# Verify entitlements applied\n", 1)[1].split(
            "# ============================================================", 1
        )[0]
        with tempfile.TemporaryDirectory(prefix="splicekit signing ") as directory:
            root = Path(directory)
            (root / "input.plist").write_bytes(payload)
            if real_signature:
                # Sign a disposable binary without executing it or touching FCP.
                shutil.copyfile("/usr/bin/true", root / "signature probe")
                subprocess.run(
                    ["/usr/bin/codesign", "--force", "--sign", "-", "--entitlements",
                     str(root / "input.plist"), str(root / "signature probe")],
                    check=True, capture_output=True, text=True,
                )
            harness = r"""
set -euo pipefail
BUILD_DIR="$1"
MODDED_APP="$BUILD_DIR/signature probe"
CODESIGN_STATUS="$2"
if [[ "$3" != "real" ]]; then
    codesign() { cat "$BUILD_DIR/input.plist"; return "$CODESIGN_STATUS"; }
fi
log() { printf '%s\n' "$*"; }
err() { printf '%s\n' "$*" >&2; }
"""
            return subprocess.run(
                ["/bin/bash", "-c", harness + block, "verification", directory,
                 str(codesign_status), "real" if real_signature else "fixture"],
                capture_output=True,
                text=True,
            )

    def test_enabled_entitlements_pass(self):
        payload = plistlib.dumps({
            "com.apple.security.cs.disable-library-validation": True,
            PHOTOS_LIBRARY: True,
        })
        result = self.run_verification(payload)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_real_signed_entitlements_pass(self):
        payload = plistlib.dumps({
            "com.apple.security.cs.disable-library-validation": True,
            PHOTOS_LIBRARY: True,
        })
        result = self.run_verification(payload, real_signature=True)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_missing_disabled_or_wrong_type_entitlements_fail(self):
        for key in ("com.apple.security.cs.disable-library-validation", PHOTOS_LIBRARY):
            for value in (None, False, "true"):
                with self.subTest(key=key, value=value):
                    entitlements = {
                        "com.apple.security.cs.disable-library-validation": True,
                        PHOTOS_LIBRARY: True,
                    }
                    if value is None:
                        del entitlements[key]
                    else:
                        entitlements[key] = value
                    result = self.run_verification(plistlib.dumps(entitlements))
                    self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
                    self.assertIn(key, result.stdout + result.stderr)

    def test_failed_codesign_or_malformed_output_fail(self):
        for payload, status in (
            (plistlib.dumps({"com.apple.security.cs.disable-library-validation": True, PHOTOS_LIBRARY: True}), 1),
            (b"not a plist: disable-library-validation", 0),
        ):
            with self.subTest(payload=payload, codesign_status=status):
                result = self.run_verification(payload, codesign_status=status)
                self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)


@unittest.skipUnless(sys.platform == "darwin", "GUI diagnostic tests compile the Swift helpers")
class GUIDiagnosticValueTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temporary_directory = tempfile.TemporaryDirectory(prefix="splicekit diagnostics ")
        cls.addClassCleanup(cls.temporary_directory.cleanup)
        root = Path(cls.temporary_directory.name)
        source = (ROOT / "patcher/SpliceKit/Models/PatcherModel.swift").read_text()
        # Execute the actual install and update diagnostic blocks with fixture output.
        blocks = re.findall(r"        let entOut = shell\(.*?\n        }\n", source, re.DOTALL)
        if len(blocks) != 2:
            raise AssertionError("Expected install and update entitlement diagnostics")
        harness = """
import Foundation

struct DiagnosticHarness {
    let output: String
    func shell(_ command: String) -> String { output }
    func logAsync(_ message: String) async { print(message) }
    func run() async {
        let moddedApp = "fixture app"
""" + "\n".join("do {\n" + block + "}\n" for block in blocks) + """
    }
}

let input = FileHandle.standardInput.readDataToEndOfFile()
await DiagnosticHarness(output: String(data: input, encoding: .utf8) ?? "").run()
"""
        main = root / "main.swift"
        main.write_text(harness)
        cls.binary = root / "diagnostics"
        result = subprocess.run(
            ["xcrun", "swiftc", "-module-cache-path", str(root / "module-cache"),
             str(ROOT / "patcher/SpliceKit/Models/ShellHelpers.swift"), str(main),
             "-o", str(cls.binary)],
            capture_output=True, text=True,
        )
        if result.returncode:
            raise AssertionError(result.stdout + result.stderr)

    def diagnostics(self, payload):
        result = subprocess.run([str(self.binary)], input=payload, capture_output=True)
        self.assertEqual(result.returncode, 0, result.stderr.decode())
        return result.stdout.decode().splitlines()

    def test_photos_requires_boolean_true_in_both_paths(self):
        for value in (True, False, None, "true", 1):
            with self.subTest(value=value):
                entitlements = {"com.apple.security.app-sandbox": False}
                if value is not None:
                    entitlements[PHOTOS_LIBRARY] = value
                lines = self.diagnostics(plistlib.dumps(entitlements))
                status = "present" if value is True else "MISSING"
                self.assertEqual(lines.count(f"Entitlement photos-library: {status}"), 2)
                self.assertEqual(lines.count("Entitlement app-sandbox: present"), 2)

    def test_malformed_output_reports_photos_missing(self):
        for payload in (b"", b"invalid plist com.apple.security.personal-information.photos-library <true/>"):
            with self.subTest(payload=payload):
                lines = self.diagnostics(payload)
                self.assertEqual(lines.count("Entitlement photos-library: MISSING"), 2)


if __name__ == "__main__":
    unittest.main()
