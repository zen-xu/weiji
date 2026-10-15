#!/usr/bin/env python3
"""Verify two distinct builds share a certificate-bound identity; requires signing setup."""
import pathlib
import plistlib
import re
import subprocess
import sys
import tempfile

root = pathlib.Path(__file__).resolve().parents[2]
sign = [sys.executable, str(root / "Scripts/sign_app.py")]
subprocess.run(sign + ["--check"], check=True)
with tempfile.TemporaryDirectory(prefix="wechat-signing-identity-test-") as directory:
    base = pathlib.Path(directory)

    def fixture(name, version, identifier="local.wechat-listener.signing-fixture"):
        app = base / (name + ".app")
        (app / "Contents/MacOS").mkdir(parents=True)
        (app / "Contents/Info.plist").write_bytes(plistlib.dumps({"CFBundleIdentifier": identifier,
            "CFBundleExecutable": "Fixture", "CFBundlePackageType": "APPL", "CFBundleVersion": str(version)}))
        source = base / (name + ".c")
        source.write_text(f'int main(void) {{ return {version}; }}\n')
        subprocess.run(["clang", str(source), "-o", str(app / "Contents/MacOS/Fixture")], check=True)
        return app

    def requirement(app):
        value = subprocess.run(["codesign", "--display", "-r-", str(app)], capture_output=True, text=True, check=True)
        result = re.search(r"designated => (.+)", value.stdout + value.stderr)
        assert result and "cdhash" not in result[1] and "certificate" in result[1], "Identity must be certificate-bound"
        return result[1]

    first, second = fixture("First", 1), fixture("Second", 2)
    for app in [first, second]:
        subprocess.run(sign + [str(app)], check=True)
    old, new = requirement(first), requirement(second)
    assert old == new, "Changing code or bundle version must not rotate the identity"
    for app, expected in [(second, old), (first, new)]:
        subprocess.run(["codesign", "--verify", "--strict", "-R=" + expected, str(app)], check=True)
    impersonator = fixture("AdHoc", 3)
    subprocess.run(["codesign", "--force", "--sign", "-", str(impersonator)], check=True)
    assert subprocess.run(["codesign", "--verify", "-R=" + old, str(impersonator)], capture_output=True).returncode != 0
    other = fixture("OtherIdentifier", 4, "local.wechat-listener.other-fixture")
    subprocess.run(sign + [str(other)], check=True)
    assert subprocess.run(["codesign", "--verify", "-R=" + old, str(other)], capture_output=True).returncode != 0
    print("PASS: two changed builds share an identity; ad-hoc and different bundle IDs cannot impersonate it.")
