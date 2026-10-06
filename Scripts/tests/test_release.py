import base64
import json
import os
import plistlib
import subprocess
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

from Scripts.asc_poll import der_to_raw, poll, token
from Scripts.release_helpers import export_options, verify_archive, write_key


class ReleaseTests(unittest.TestCase):
    def test_key_permissions_literal_newlines_and_no_overwrite(self):
        with tempfile.TemporaryDirectory() as root:
            directory = Path(root) / "asc"
            env = {"ASC_KEY_ID": "test", "ASC_ISSUER_ID": "test", "ASC_TEAM_ID": "test",
                   "ASC_KEY_P8": "-----BEGIN PRIVATE KEY-----\\nfixture\\n-----END PRIVATE KEY-----"}
            with patch.dict(os.environ, env):
                key = write_key(directory)
                self.assertEqual(key.stat().st_mode & 0o777, 0o600)
                self.assertEqual(directory.stat().st_mode & 0o777, 0o700)
                self.assertNotIn("\\n", key.read_text())
                with self.assertRaises(FileExistsError):
                    write_key(directory)

    def test_missing_secret_does_not_create_key(self):
        with tempfile.TemporaryDirectory() as root, patch.dict(os.environ, {}, clear=True):
            with self.assertRaisesRegex(ValueError, "ASC_KEY_ID"):
                write_key(Path(root) / "asc")
            self.assertFalse((Path(root) / "asc").exists())

    def test_export_defaults_never_upload_and_no_build_rewrite(self):
        preview = export_options("TEST", False)
        self.assertEqual(preview["destination"], "export")
        self.assertNotIn("uploadMethod", preview)
        self.assertFalse(preview["manageAppVersionAndBuildNumber"])
        upload = export_options("TEST", True)
        self.assertEqual(upload["destination"], "upload")
        self.assertEqual(upload["uploadMethod"], "app-store-connect")
        self.assertEqual(upload["method"], "app-store-connect")

    def test_archive_fail_closed_on_family_id_build_sdk_and_icon(self):
        valid = {"CFBundleIdentifier": "com.infinityball.pumplog", "UIDeviceFamily": [1],
                 "CFBundleVersion": "42", "CFBundleShortVersionString": "0.1.0",
                 "DTSDKName": "iphoneos26.0", "DTXcodeBuild": "17A400"}
        with tempfile.TemporaryDirectory() as root:
            app = Path(root)
            (app / "Assets.car").touch()
            (app / "AppIcon60x60@2x.png").touch()
            for key, bad in (("UIDeviceFamily", [1, 2]), ("CFBundleIdentifier", "wrong"),
                             ("CFBundleVersion", "41"), ("DTSDKName", "iphoneos26.5"),
                             ("DTXcodeBuild", "wrong")):
                (app / "Info.plist").write_bytes(plistlib.dumps(valid | {key: bad}))
                with self.assertRaisesRegex(ValueError, key):
                    verify_archive(app, "42")
            (app / "Info.plist").write_bytes(plistlib.dumps(valid))
            self.assertEqual(verify_archive(app, "42")["marketing_version"], "0.1.0")
            (app / "Assets.car").unlink()
            with self.assertRaisesRegex(ValueError, "icon"):
                verify_archive(app, "42")

    def test_jwt_has_raw_64_byte_signature_and_valid_claims(self):
        with tempfile.TemporaryDirectory() as root:
            key = Path(root) / "fixture.p8"
            subprocess.run(["openssl", "genpkey", "-algorithm", "EC", "-pkeyopt", "ec_paramgen_curve:P-256", "-out", str(key)], check=True, capture_output=True)
            with patch.dict(os.environ, ASC_KEY_ID="TEST", ASC_ISSUER_ID="TEST"):
                jwt = token(key)
            header, claims, signature = [base64.urlsafe_b64decode(p + "=" * (-len(p) % 4)) for p in jwt.split(".")]
            self.assertEqual(len(signature), 64)
            self.assertEqual(json.loads(header)["alg"], "ES256")
            self.assertEqual(json.loads(claims)["aud"], "appstoreconnect-v1")
            self.assertEqual(json.loads(claims)["exp"] - json.loads(claims)["iat"], 600)

    def test_der_invalid_signature_rejected(self):
        for bad in (b"", b"nonsense", b"\x30\x06\x02\x01\x80\x02\x01\x01"):
            with self.assertRaises((ValueError, IndexError)):
                der_to_raw(bad)

    def run_poll(self, states):
        now = [0]
        def sleep(seconds):
            now[0] += seconds
        sequence = iter(states)
        def fetch():
            state = next(sequence, None)
            return [] if state is None else [{"id": "fixture-build", "attributes": {"version": "42", "processingState": state},
                    "relationships": {"preReleaseVersion": {"data": {"id": "fixture-version"}}}}]
        return poll(fetch, "42", "0.1.0", timeout=90, clock=lambda: now[0], sleep=sleep)

    def test_poll_absent_processing_then_complete(self):
        result = self.run_poll([None, "PROCESSING", "COMPLETE"])
        self.assertEqual(result["build_id"], "fixture-build")
        self.assertEqual(result["processingState"], "COMPLETE")

    def test_apple_valid_preserves_raw_state(self):
        result = self.run_poll(["VALID"])
        self.assertEqual(result["processingState"], "VALID")
        self.assertEqual(result["processing_stage"], "COMPLETE")

    def test_poll_timeout_and_failure_are_not_success(self):
        with self.assertRaises(TimeoutError):
            self.run_poll([None])
        for state in ("FAILED", "INVALID", "mystery"):
            with self.assertRaises(ValueError):
                self.run_poll([state])

    def test_source_release_contract(self):
        root = Path(__file__).resolve().parents[2]
        workflow = (root / ".github/workflows/release.yml").read_text()
        self.assertIn("workflow_dispatch:", workflow)
        self.assertNotIn("  push:", workflow)
        self.assertNotIn("  pull_request:", workflow)
        self.assertIn("CURRENT_PROJECT_VERSION=\"$GITHUB_RUN_NUMBER\"", workflow)
        self.assertIn("if: always()", workflow)
        self.assertIn("rm -f \"$RUNNER_TEMP/pump-log-asc/AuthKey.p8\"", workflow)
        self.assertNotIn("set -x", workflow)
        project = (root / "PumpLog.xcodeproj/project.pbxproj").read_text()
        self.assertEqual(project.count("ASSETCATALOG_COMPILER_APPICON_NAME = AppIcon;"), 2)
        self.assertEqual(project.count("PRODUCT_BUNDLE_IDENTIFIER = com.infinityball.pumplog;"), 2)
        self.assertNotIn("TARGETED_DEVICE_FAMILY = 1,2", project)
        # PNG IHDR: width/height=1024; color type 2 = opaque RGB.
        png = (root / "App/Assets.xcassets/AppIcon.appiconset/AppIcon.png").read_bytes()
        self.assertEqual(png[:8], b"\x89PNG\r\n\x1a\n")
        self.assertEqual(int.from_bytes(png[16:20], "big"), 1024)
        self.assertEqual(int.from_bytes(png[20:24], "big"), 1024)
        self.assertEqual(png[25], 2)
