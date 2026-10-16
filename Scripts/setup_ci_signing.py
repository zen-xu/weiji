#!/usr/bin/env python3
"""Create a release-only certificate and store its key in GitHub encrypted secrets, never local trust."""
import argparse
import base64
import hashlib
import json
import os
import pathlib
import re
import secrets
import subprocess
import tempfile

ROOT = pathlib.Path(__file__).resolve().parent.parent
NAMES = ["RELEASE_CERTIFICATE_BASE64", "RELEASE_CERTIFICATE_PASSWORD", "RELEASE_CERTIFICATE_SHA1"]


def run(command, **kwargs):
    result = subprocess.run(command, capture_output=True, **kwargs)
    if result.returncode:
        raise RuntimeError(f"Command failed: {command[0]} {command[1]}; no secret values were logged.")
    return result.stdout


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repo", required=True, help="Explicit owner/repository receiving the new release key")
    options = parser.parse_args()
    if not re.fullmatch(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", options.repo):
        raise RuntimeError("Expected owner/repository.")
    existing = json.loads(run(["gh", "secret", "list", "--repo", options.repo, "--json", "name"], text=True))
    configured = set(NAMES) & {item["name"] for item in existing}
    public = ROOT / "Resources/ReleaseSigning.cer"
    if configured:
        if configured == set(NAMES) and public.exists():
            print("Existing CI release identity retained; no key was rotated.")
            return
        raise RuntimeError("Partial CI identity exists. Refusing to overwrite or rotate existing secrets.")
    if public.exists():
        raise RuntimeError("Pinned public certificate already exists. Refusing automatic identity rotation.")
    with tempfile.TemporaryDirectory(prefix="weiji-ci-identity-") as temporary:
        root = pathlib.Path(temporary)
        config = root / "openssl.cnf"
        config.write_text("""[req]
prompt=no
distinguished_name=dn
x509_extensions=codesign
[dn]
CN=Weiji GitHub Release Code Signing
O=zen-xu wechat-listener
[codesign]
basicConstraints=critical,CA:FALSE
keyUsage=critical,digitalSignature
extendedKeyUsage=critical,codeSigning
subjectKeyIdentifier=hash
""")
        private, certificate, archive = root / "private.key", root / "certificate.pem", root / "identity.p12"
        run(["/usr/bin/openssl", "req", "-new", "-newkey", "rsa:3072", "-nodes", "-x509", "-days", "3650", "-sha256",
             "-config", str(config), "-keyout", str(private), "-out", str(certificate)])
        password = secrets.token_urlsafe(48)
        environment = os.environ.copy()
        environment["WEIJI_P12_PASSWORD"] = password
        run(["/usr/bin/openssl", "pkcs12", "-export", "-inkey", str(private), "-in", str(certificate), "-name",
             "Weiji GitHub Release Code Signing", "-out", str(archive), "-passout", "env:WEIJI_P12_PASSWORD"], env=environment)
        der = run(["/usr/bin/openssl", "x509", "-in", str(certificate), "-outform", "der"])
        fingerprint = hashlib.sha1(der).hexdigest().upper()
        values = [base64.b64encode(archive.read_bytes()).decode(), password, fingerprint]
        created = []
        try:
            for name, value in zip(NAMES, values):
                run(["gh", "secret", "set", name, "--repo", options.repo], input=value.encode())
                created.append(name)
        except RuntimeError:
            for name in created:
                run(["gh", "secret", "delete", name, "--repo", options.repo])
            raise
        public.write_bytes(der)
        public.chmod(0o644)
    print(f"Configured 3 encrypted release secrets in {options.repo}.")
    print(f"Public certificate SHA-1: {fingerprint}. Local signing keychain and trust were not modified.")


if __name__ == "__main__":
    os.umask(0o077)
    main()
