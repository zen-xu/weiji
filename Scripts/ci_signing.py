#!/usr/bin/env python3
"""Import the pinned release identity only into a disposable GitHub-hosted runner."""
import base64
import hashlib
import json
import os
import pathlib
import re
import secrets
import shlex
import shutil
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent


def run(arguments, **kwargs):
    result = subprocess.run(arguments, capture_output=True, **kwargs)
    if result.returncode:
        # Arguments may contain an ephemeral keychain/password. Never print them or command output.
        raise RuntimeError(f"CI signing command failed: {arguments[0]} {arguments[1]}")
    return result.stdout


def runner_directory():
    if os.environ.get("GITHUB_ACTIONS") != "true" or os.environ.get("RUNNER_ENVIRONMENT") != "github-hosted":
        raise RuntimeError("CI signing is restricted to disposable GitHub-hosted runners; local keychains are untouched.")
    return pathlib.Path(os.environ["RUNNER_TEMP"]) / "weiji-release-signing"


def install(directory):
    identity = os.environ.get("RELEASE_CERTIFICATE_SHA1", "")
    if not re.fullmatch(r"[A-F0-9]{40}", identity):
        raise RuntimeError("Missing or invalid pinned release certificate fingerprint.")
    password = os.environ.get("RELEASE_CERTIFICATE_PASSWORD")
    if not password:
        raise RuntimeError("Missing release certificate password.")
    certificate = (ROOT / "Resources/ReleaseSigning.cer").read_bytes()
    if hashlib.sha1(certificate).hexdigest().upper() != identity:
        raise RuntimeError("Release certificate does not match the committed public certificate.")
    directory.mkdir(mode=0o700)
    keychain = directory / "release.keychain-db"
    previous = shlex.split(run(["security", "list-keychains", "-d", "user"], text=True))
    (directory / "state.json").write_text(json.dumps({"keychains": previous}))
    (directory / "certificate.cer").write_bytes(certificate)
    archive = directory / "identity.p12"
    archive.write_bytes(base64.b64decode(os.environ["RELEASE_CERTIFICATE_BASE64"], validate=True))
    keychain_password = secrets.token_urlsafe(32)
    run(["security", "create-keychain", "-p", keychain_password, str(keychain)])
    run(["security", "set-keychain-settings", "-lut", "21600", str(keychain)])
    run(["security", "unlock-keychain", "-p", keychain_password, str(keychain)])
    run(["security", "import", str(archive), "-k", str(keychain), "-P", password, "-T", "/usr/bin/codesign"])
    archive.unlink()
    run(["security", "add-trusted-cert", "-r", "trustRoot", "-p", "codeSign", "-k", str(keychain), str(directory / "certificate.cer")])
    run(["security", "set-key-partition-list", "-S", "apple-tool:,apple:,codesign:", "-s", "-k", keychain_password, str(keychain)])
    run(["security", "list-keychains", "-d", "user", "-s", str(keychain), *previous])
    identities = run(["security", "find-identity", "-v", "-p", "codesigning", str(keychain)], text=True)
    if identity not in re.findall(r'\d+\) ([A-F0-9]{40}) "', identities):
        raise RuntimeError("Imported key does not provide the pinned release signing identity.")
    with open(os.environ["GITHUB_ENV"], "a") as output:
        output.write(f"CODE_SIGN_IDENTITY={identity}\nCODE_SIGN_KEYCHAIN={keychain}\n")
    print("Pinned release identity installed in the disposable runner keychain.")


def cleanup(directory):
    if not directory.exists():
        return
    certificate = directory / "certificate.cer"
    if certificate.exists():
        subprocess.run(["security", "remove-trusted-cert", str(certificate)], capture_output=True)
    state = directory / "state.json"
    if state.exists():
        previous = json.loads(state.read_text())["keychains"]
        run(["security", "list-keychains", "-d", "user", "-s", *previous])
    keychain = directory / "release.keychain-db"
    if keychain.exists():
        run(["security", "delete-keychain", str(keychain)])
    shutil.rmtree(directory)
    print("Temporary release keychain and certificate material removed.")


if __name__ == "__main__":
    os.umask(0o077)
    try:
        directory = runner_directory()
        if sys.argv[1:] == ["install"]:
            install(directory)
        elif sys.argv[1:] == ["cleanup"]:
            cleanup(directory)
        else:
            raise RuntimeError("Usage: ci_signing.py install|cleanup")
    except (RuntimeError, ValueError, KeyError, OSError) as error:
        print(str(error), file=sys.stderr)
        sys.exit(1)
