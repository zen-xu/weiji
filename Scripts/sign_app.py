#!/usr/bin/env python3
"""Sign with a pinned local identity or an explicitly selected development identity."""
import json
import os
import pathlib
import re
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
CONFIG = ROOT / ".local-signing/identity.json"


def settings():
    identity = os.environ.get("CODE_SIGN_IDENTITY")
    keychain = os.environ.get("CODE_SIGN_KEYCHAIN")
    if not identity:
        if not CONFIG.is_file():
            raise RuntimeError("尚未配置固定签名。先阅读 Documentation/Signing.md 并配置身份；仅临时测试可显式设置 CODE_SIGN_IDENTITY=-。")
        config = json.loads(CONFIG.read_text())
        identity, keychain = config["identity"], config["keychain"]
        if not re.fullmatch(r"[0-9A-F]{40}", identity):
            raise RuntimeError("本机签名配置无效，请检查 .local-signing/identity.json。")
    if identity == "-":
        print("警告：显式使用临时签名；此构建更新后可能需要重新授予完全磁盘访问。", file=sys.stderr)
        return identity, keychain
    command = ["security", "find-identity", "-v", "-p", "codesigning"]
    if keychain:
        command.append(keychain)
    result = subprocess.run(command, capture_output=True, text=True, check=True)
    matches = re.findall(r'\d+\) ([0-9A-F]{40}) "([^"]+)"', result.stdout)
    selected = [fingerprint for fingerprint, name in matches if identity.upper() == fingerprint or identity == name]
    if len(selected) != 1:
        raise RuntimeError("找不到唯一有效的固定签名身份。请检查钥匙串是否已解锁及证书是否有效；不会自动更换证书或降级为临时签名。")
    return selected[0], keychain


def main():
    identity, keychain = settings()
    if sys.argv[1:] == ["--check"]:
        print("签名身份检查通过。")
        return
    if len(sys.argv) != 2:
        raise RuntimeError("用法：python3 Scripts/sign_app.py --check | 应用路径")
    app = pathlib.Path(sys.argv[1]).resolve()
    command = ["codesign", "--force", "--sign", identity, "--timestamp=none"]
    if keychain:
        command += ["--keychain", keychain]
    subprocess.run(command + [str(app)], check=True)
    subprocess.run(["codesign", "--verify", "--strict", "--verbose=2", str(app)], check=True)
    displayed = subprocess.run(["codesign", "--display", "-r-", str(app)], capture_output=True, text=True, check=True)
    requirement = displayed.stdout + displayed.stderr
    if identity != "-" and ("cdhash" in requirement or "certificate" not in requirement):
        raise RuntimeError("签名未形成证书约束的稳定身份，拒绝交付此构建。")
    print(requirement.strip())


if __name__ == "__main__":
    try:
        main()
    except (RuntimeError, KeyError, ValueError, OSError, subprocess.CalledProcessError) as error:
        print(f"签名失败：{error}", file=sys.stderr)
        sys.exit(1)
