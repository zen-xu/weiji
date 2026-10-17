#!/usr/bin/env python3
"""Release guards: reject version drift, incomplete/tampered assets and local keychain access."""
import importlib.util
import json
import os
import pathlib
import plistlib
import tempfile
import unittest
import subprocess
from unittest import mock

ROOT = pathlib.Path(__file__).resolve().parents[2]


def module(name, path):
    spec = importlib.util.spec_from_file_location(name, ROOT / path)
    result = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(result)
    return result


release = module("release", "Scripts/release.py")
signing = module("ci_signing", "Scripts/ci_signing.py")
setup = module("setup_ci_signing", "Scripts/setup_ci_signing.py")


class ReleaseTests(unittest.TestCase):
    def setUp(self):
        self.info = plistlib.loads((ROOT / "Resources/Info.plist").read_bytes())

    def test_exact_version_tag_and_existing_identity(self):
        version = self.info["CFBundleShortVersionString"]
        self.assertEqual(release.validate("v" + version, self.info), version)
        for tag in [version, "v99.0.0", "v" + version + "-rc.1", "v" + version + "/../main"]:
            with self.assertRaises(ValueError):
                release.validate(tag, self.info)

    def test_invalid_versions_and_builds_cannot_publish(self):
        for version in ["01.0.0", "0.01.0", "1.2", "1.2.3.4", "1.2.3-rc.1", "../1.2.3"]:
            with self.assertRaises(ValueError):
                release.validate(info={**self.info, "CFBundleShortVersionString": version})
        for build in ["0", "-1", "1.0", " 1", "01"]:
            with self.assertRaises(ValueError):
                release.validate(info={**self.info, "CFBundleVersion": build})
        with self.assertRaises(ValueError):
            release.validate(info={**self.info, "CFBundleIdentifier": "new.identity"})

    def assets(self, root, version=None):
        version = version or self.info["CFBundleShortVersionString"]
        for name in release.asset_names(version)[:2]:
            (root / name).write_bytes(b"synthetic-release-only")
        (root / "release-manifest.json").write_text(json.dumps({"version": version, "tag": "v" + version}))
        (root / "SHA256SUMS").write_text("".join(
            f"{release.file_hash(p)}  {p.name}\n" for p in sorted(root.iterdir()) if p.name != "SHA256SUMS"))
        return version

    def test_missing_and_modified_assets_are_rejected(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary)
            with self.assertRaises(ValueError):
                release.verified_assets(root, self.info["CFBundleShortVersionString"])
            version = self.assets(root)
            self.assertEqual(len(release.verified_assets(root, version)), 4)
            (root / release.ASSETS[0].format(version=version)).write_bytes(b"modified")
            with self.assertRaises(ValueError):
                release.verified_assets(root, version)

    def test_checksum_path_traversal_and_duplicates_are_rejected(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary)
            version = self.assets(root)
            original = (root / "SHA256SUMS").read_text()
            for extra in [original.splitlines()[0] + "\n", "0" * 64 + "  ../outside.zip\n"]:
                (root / "SHA256SUMS").write_text(original + extra)
                with self.assertRaises(ValueError):
                    release.verified_assets(root, version)

    def test_new_releases_reject_intel_and_universal_binaries_before_execution(self):
        version = self.info["CFBundleShortVersionString"]
        with tempfile.TemporaryDirectory() as temporary:
            app = pathlib.Path(temporary) / "fixture.app"
            (app / "Contents").mkdir(parents=True)
            (app / "Contents/Info.plist").write_bytes(plistlib.dumps(self.info))
            for architectures in ["x86_64", "arm64 x86_64", "arm64e", ""]:
                with self.subTest(architectures=architectures), \
                     mock.patch.object(release, "run", return_value=architectures) as command:
                    with self.assertRaisesRegex(ValueError, "architectures must be exactly"):
                        release.verify_app(app, "v" + version)
                    command.assert_called_once()

    def test_arm64_and_historical_universal_signature_verification(self):
        with tempfile.TemporaryDirectory() as temporary:
            app = pathlib.Path(temporary) / "fixture.app"
            (app / "Contents").mkdir(parents=True)
            for version, architectures, current in [
                (self.info["CFBundleShortVersionString"], "arm64", True),
                ("0.4.0", "arm64 x86_64", False),
            ]:
                info = {**self.info, "CFBundleShortVersionString": version}
                (app / "Contents/Info.plist").write_bytes(plistlib.dumps(info))
                with mock.patch.object(release, "run", side_effect=[architectures, version, ""]) as command:
                    actual, slices, _ = release.verify_app(app, "v" + version, match_source=current)
                    self.assertEqual(actual, info)
                    self.assertEqual(slices, architectures.split())
                    self.assertIn("--all-architectures", command.call_args.args[0])
                    self.assertTrue(any("certificate root" in arg for arg in command.call_args.args[0]))

    def test_historical_asset_names_remain_verifiable_but_cannot_replace_arm64(self):
        for version in ["0.1.0", "0.4.0", self.info["CFBundleShortVersionString"], "0.10.0", "1.0.0"]:
            with tempfile.TemporaryDirectory() as temporary:
                root = pathlib.Path(temporary)
                self.assets(root, version)
                paths = release.verified_assets(root, version)
                architecture = "universal" if version in ["0.1.0", "0.4.0"] else "arm64"
                self.assertEqual(paths[0].name, f"Weiji-{version}-macos-{architecture}.zip")
                other = "arm64" if architecture == "universal" else "universal"
                paths[0].rename(root / paths[0].name.replace(architecture, other))
                with self.assertRaises(ValueError):
                    release.verified_assets(root, version)

    def test_publisher_refuses_replacing_published_release(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary)
            version = self.assets(root)
            with mock.patch.object(release, "validate", return_value=version), \
                 mock.patch.object(release, "verified_assets", return_value=[]), \
                 mock.patch.object(release, "run", return_value=json.dumps([[{"tag_name": "v" + version, "draft": False}]])) as command:
                with self.assertRaisesRegex(ValueError, "Published release already exists"):
                    release.publish("v" + version)
                self.assertEqual(command.call_count, 1)

    def test_ci_keychain_setup_refuses_local_and_self_hosted_machines(self):
        for env in [{}, {"GITHUB_ACTIONS": "true", "RUNNER_ENVIRONMENT": "self-hosted"}]:
            with mock.patch.dict(os.environ, env, clear=True), mock.patch.object(signing.subprocess, "run") as command:
                with self.assertRaises(RuntimeError):
                    signing.runner_directory()
                command.assert_not_called()

    def test_ci_timeout_does_not_expose_command_passwords(self):
        with mock.patch.object(signing.subprocess, "run", side_effect=subprocess.TimeoutExpired(["security", "secret-value"], 60)):
            with self.assertRaises(RuntimeError) as error:
                signing.run(["security", "unlock-keychain", "-p", "secret-value", "fixture"])
        self.assertNotIn("secret-value", str(error.exception))

    def test_cleanup_deletes_private_keychain_without_waiting_for_public_trust_revocation(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary) / "signing"
            root.mkdir()
            (root / "state.json").write_text(json.dumps({"keychains": ["fixture-login"]}))
            (root / "release.keychain-db").write_bytes(b"synthetic-keychain-only")
            (root / "certificate.cer").write_bytes(b"public-certificate-only")
            with mock.patch.object(signing, "run") as command:
                signing.cleanup(root)
            self.assertEqual([call.args[0][1] for call in command.call_args_list], ["list-keychains", "delete-keychain"])
            self.assertFalse(root.exists())

    def test_bootstrap_never_rotates_existing_or_partial_secrets(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary)
            (root / "Resources").mkdir()
            (root / "Resources/ReleaseSigning.cer").write_bytes(b"public-certificate-only")
            for names in [setup.NAMES, setup.NAMES[:1]]:
                with mock.patch.object(setup, "ROOT", root), \
                     mock.patch("sys.argv", ["setup_ci_signing.py", "--repo", "fixture/repo"]), \
                     mock.patch.object(setup, "run", return_value=json.dumps([{"name": n} for n in names])) as command:
                    if names == setup.NAMES:
                        setup.main()
                    else:
                        with self.assertRaisesRegex(RuntimeError, "Partial CI identity"):
                            setup.main()
                    self.assertEqual(command.call_count, 1)


if __name__ == "__main__":
    unittest.main()
