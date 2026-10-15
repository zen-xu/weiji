#!/usr/bin/env python3
"""Test signing configuration without opening a keychain or changing trust settings."""
import importlib.util
import json
import os
import pathlib
import subprocess
import tempfile
import unittest
from unittest import mock

root = pathlib.Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("sign_app", root / "Scripts/sign_app.py")
signing = importlib.util.module_from_spec(spec)
spec.loader.exec_module(signing)
setup_spec = importlib.util.spec_from_file_location("setup_signing", root / "Scripts/setup_signing.py")
setup = importlib.util.module_from_spec(setup_spec)
setup_spec.loader.exec_module(setup)


class SigningConfigTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="wechat-signing-config-test-")
        self.config = pathlib.Path(self.temporary.name) / "identity.json"
        self.env = mock.patch.dict(os.environ, {}, clear=True)
        self.path = mock.patch.object(signing, "CONFIG", self.config)
        self.env.start()
        self.path.start()
        self.addCleanup(self.temporary.cleanup)
        self.addCleanup(self.env.stop)
        self.addCleanup(self.path.stop)

    def configure(self):
        self.config.write_text(json.dumps({"identity": "A" * 40, "keychain": "/fixture/login.keychain-db"}))

    def test_missing_identity_never_falls_back_to_adhoc(self):
        with self.assertRaisesRegex(RuntimeError, "尚未配置固定签名"):
            signing.settings()

    def test_config_pins_exact_certificate_not_a_shared_label(self):
        self.configure()
        output = '  1) ' + 'A' * 40 + ' "Local Signing"\n  2) ' + 'B' * 40 + ' "Local Signing"\n'
        with mock.patch.object(signing.subprocess, "run", return_value=subprocess.CompletedProcess([], 0, output, "")) as run:
            self.assertEqual(signing.settings(), ("A" * 40, "/fixture/login.keychain-db"))
            self.assertEqual(run.call_args.args[0], ["security", "find-identity", "-v", "-p", "codesigning", "/fixture/login.keychain-db"])

    def test_missing_pinned_certificate_cannot_silently_rotate(self):
        self.configure()
        output = '  1) ' + 'B' * 40 + ' "Local Signing"\n'
        with mock.patch.object(signing.subprocess, "run", return_value=subprocess.CompletedProcess([], 0, output, "")):
            with self.assertRaisesRegex(RuntimeError, "不会自动更换证书"):
                signing.settings()

    def test_ambiguous_explicit_name_is_rejected(self):
        os.environ["CODE_SIGN_IDENTITY"] = "Local Signing"
        output = ''.join(f'  {index}) {char * 40} "Local Signing"\n' for index, char in [(1, "A"), (2, "B")])
        with mock.patch.object(signing.subprocess, "run", return_value=subprocess.CompletedProcess([], 0, output, "")):
            with self.assertRaises(RuntimeError):
                signing.settings()

    def test_adhoc_requires_explicit_opt_in(self):
        os.environ["CODE_SIGN_IDENTITY"] = "-"
        with mock.patch.object(signing.subprocess, "run") as run:
            self.assertEqual(signing.settings(), ("-", None))
            run.assert_not_called()

    def test_invalid_config_does_not_access_the_keychain(self):
        self.config.write_text(json.dumps({"identity": "not-a-fingerprint", "keychain": "/fixture/keychain"}))
        with mock.patch.object(signing.subprocess, "run") as run:
            with self.assertRaisesRegex(RuntimeError, "配置无效"):
                signing.settings()
            run.assert_not_called()

    def test_initial_setup_requires_explicit_trust_confirmation(self):
        previous_umask = os.umask(0o077)
        try:
            with mock.patch.object(setup, "CONFIG", self.config), mock.patch.object(setup.sys, "argv", ["setup_signing.py"]), mock.patch.object(setup.subprocess, "run") as run:
                with self.assertRaisesRegex(RuntimeError, "--confirm-local-trust"):
                    setup.main()
                run.assert_not_called()
        finally:
            os.umask(previous_umask)

    def test_setup_reuse_checks_pinned_config_even_with_adhoc_environment(self):
        os.environ["CODE_SIGN_IDENTITY"] = "-"
        os.environ["CODE_SIGN_KEYCHAIN"] = "/fixture/other-keychain"
        with mock.patch.object(setup.subprocess, "run") as run:
            setup.check_config()
            self.assertNotIn("CODE_SIGN_IDENTITY", run.call_args.kwargs["env"])
            self.assertNotIn("CODE_SIGN_KEYCHAIN", run.call_args.kwargs["env"])


if __name__ == "__main__":
    unittest.main()
