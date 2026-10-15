#!/usr/bin/env python3
"""Create/reuse a local signing identity in the login keychain; never store a private key in the repo."""
import argparse
import hashlib
import json
import os
import pathlib
import re
import shlex
import subprocess
import sys
import tempfile

ROOT = pathlib.Path(__file__).resolve().parent.parent
CONFIG = ROOT / ".local-signing/identity.json"
NAME = "WeChatListener Local Code Signing"


def run(command):
    result = subprocess.run(command, capture_output=True, text=True)
    if result.returncode:
        raise RuntimeError(result.stderr.strip() or "签名身份配置命令失败。")
    return result.stdout


def check_config():
    environment = os.environ.copy()
    environment.pop("CODE_SIGN_IDENTITY", None)
    environment.pop("CODE_SIGN_KEYCHAIN", None)
    subprocess.run([sys.executable, str(ROOT / "Scripts/sign_app.py"), "--check"], env=environment, check=True)


def main():
    parser = argparse.ArgumentParser(description="配置并复用本机代码签名证书。新身份会添加用户级 codeSign 信任。")
    parser.add_argument("--confirm-local-trust", action="store_true", help="确认创建持久私钥并为该证书添加用户级代码签名信任")
    options = parser.parse_args()
    os.umask(0o077)
    if CONFIG.exists():
        # Never silently rotate the certificate: existing TCC grants depend on it.
        check_config()
        print("已复用固定签名身份，无需重新创建。")
        return
    if not options.confirm_local_trust:
        raise RuntimeError("首次配置需明确确认：python3 Scripts/setup_signing.py --confirm-local-trust。此操作会保存私钥并添加用户级 codeSign 信任。")
    CONFIG.parent.mkdir(mode=0o700, exist_ok=True)
    keychains = shlex.split(run(["security", "default-keychain", "-d", "user"]))
    if len(keychains) != 1:
        raise RuntimeError("无法确定当前用户的默认钥匙串。")
    keychain = keychains[0]
    identities = run(["security", "find-identity", "-p", "codesigning", keychain])
    matches = set(re.findall(r'\d+\) ([0-9A-F]{40}) "' + re.escape(NAME) + r'"', identities))
    if len(matches) > 1:
        raise RuntimeError("存在多个同名签名身份，请手动选择并配置，避免更换已有授权身份。")
    with tempfile.TemporaryDirectory(prefix="wechat-signing-setup-") as directory:
        temporary = pathlib.Path(directory)
        certificate = temporary / "certificate.pem"
        if matches:
            certificate.write_text(run(["security", "find-certificate", "-c", NAME, "-p", keychain]))
        else:
            config = temporary / "openssl.cnf"
            config.write_text(f"""[req]
prompt=no
distinguished_name=dn
x509_extensions=codesign
[dn]
CN={NAME}
O=Local Development
[codesign]
basicConstraints=critical,CA:FALSE
keyUsage=critical,digitalSignature
extendedKeyUsage=critical,codeSigning
subjectKeyIdentifier=hash
""")
            private = temporary / "private.key"
            rsa = temporary / "rsa.key"
            run(["/usr/bin/openssl", "req", "-new", "-newkey", "rsa:3072", "-nodes", "-x509", "-days", "3650", "-sha256",
                 "-config", str(config), "-keyout", str(private), "-out", str(certificate)])
            run(["/usr/bin/openssl", "rsa", "-in", str(private), "-out", str(rsa)])
            # Non-exportable private key, with codesign as the only pre-authorized tool.
            run(["security", "import", str(rsa), "-k", keychain, "-f", "openssl", "-t", "priv", "-x", "-T", "/usr/bin/codesign"])
            run(["security", "import", str(certificate), "-k", keychain, "-f", "pemseq", "-t", "cert"])
        der = subprocess.check_output(["/usr/bin/openssl", "x509", "-in", str(certificate), "-outform", "der"])
        identity = hashlib.sha1(der).hexdigest().upper()
        if matches and identity not in matches:
            raise RuntimeError("同名证书与签名身份不匹配，拒绝修改信任设置。")
        print("正在为本机专用证书设置用户级代码签名信任；如系统弹出验证，请由你完成。", flush=True)
        run(["security", "add-trusted-cert", "-r", "trustRoot", "-p", "codeSign", "-k", keychain, str(certificate)])
        CONFIG.write_text(json.dumps({"identity": identity, "keychain": keychain}, indent=2) + "\n")
        CONFIG.chmod(0o600)
        (CONFIG.parent / "certificate.cer").write_bytes(der)
    check_config()
    print("固定签名已配置。私钥保存在钥匙串，本项目仅记录证书指纹。后续直接运行 bash build.sh。")


if __name__ == "__main__":
    try:
        main()
    except (RuntimeError, OSError, subprocess.CalledProcessError) as error:
        print(f"配置失败：{error}", file=sys.stderr)
        sys.exit(1)
