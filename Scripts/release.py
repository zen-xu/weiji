#!/usr/bin/env python3
"""Validate versions, package the verified arm64 App, then publish complete draft releases."""
import argparse
import hashlib
import json
import os
import pathlib
import plistlib
import re
import shutil
import subprocess
import tempfile

ROOT = pathlib.Path(__file__).resolve().parent.parent
SEMVER = r"(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)"
ASSETS = ["Weiji-{version}-macos-arm64.zip", "Weiji-{version}-macos-arm64.dmg",
          "release-manifest.json", "SHA256SUMS"]


def release_architectures(version):
    if not re.fullmatch(SEMVER, version):
        raise ValueError("Expected a stable release version.")
    # Previously published universal releases remain verifiable without republishing.
    if tuple(map(int, version.split("."))) < (0, 4, 1):
        return ["arm64", "x86_64"]
    return ["arm64"]


def asset_names(version):
    templates = ASSETS
    if release_architectures(version) != ["arm64"]:
        templates = [name.replace("-arm64.", "-universal.") for name in ASSETS]
    return [name.format(version=version) for name in templates]


def run(command):
    return subprocess.run(command, check=True, capture_output=True, text=True).stdout.strip()


def validate(tag=None, info=None):
    if info is None:
        info = plistlib.loads((ROOT / "Resources/Info.plist").read_bytes())
    version = info["CFBundleShortVersionString"]
    if not re.fullmatch(SEMVER, version):
        raise ValueError("App version must be a stable SemVer (for example 0.1.0).")
    if not re.fullmatch(r"[1-9][0-9]*", info["CFBundleVersion"]):
        raise ValueError("Build number must be a positive integer.")
    if info["CFBundleIdentifier"] != "local.xzy.WeChatListener" or info["CFBundleExecutable"] != "WeChatListener":
        raise ValueError("Release must retain the existing bundle identity and executable.")
    if tag is not None and tag != f"v{version}":
        raise ValueError(f"Tag {tag!r} must exactly match v{version} from Resources/Info.plist.")
    return version


def file_hash(path):
    result = hashlib.sha256()
    with path.open("rb") as source:
        for block in iter(lambda: source.read(1024 * 1024), b""):
            result.update(block)
    return result.hexdigest()


def verify_app(app, tag, match_source=True):
    info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
    version = validate(tag, info)
    if match_source and info != plistlib.loads((ROOT / "Resources/Info.plist").read_bytes()):
        raise ValueError("Built bundle metadata differs from the committed release metadata.")
    binary = app / "Contents/MacOS/WeChatListener"
    architectures = sorted(run(["lipo", "-archs", str(binary)]).split())
    expected = ["arm64"] if match_source else release_architectures(version)
    if architectures != expected:
        raise ValueError(f"Release App architectures must be exactly {expected}; got {architectures}.")
    if run([str(binary), "--version"]) != version:
        raise ValueError("Executable version does not match the release tag.")
    fingerprint = hashlib.sha1((ROOT / "Resources/ReleaseSigning.cer").read_bytes()).hexdigest()
    requirement = f'identifier "{info["CFBundleIdentifier"]}" and certificate root = H"{fingerprint}"'
    run(["codesign", "--verify", "--strict", "--all-architectures", "-R=" + requirement, str(app)])
    return info, architectures, fingerprint


def package(tag):
    version = validate(tag)
    app = ROOT / "dist/微迹.app"
    info, architectures, fingerprint = verify_app(app, tag)
    output = ROOT / "dist/release"
    if output.exists():
        shutil.rmtree(output)
    output.mkdir(parents=True)
    archive = output / asset_names(version)[0]
    run(["ditto", "-c", "-k", "--sequesterRsrc", "--keepParent", str(app), str(archive)])
    with tempfile.TemporaryDirectory(prefix="weiji-release-verify-") as temporary:
        expanded = pathlib.Path(temporary) / "expanded"
        run(["ditto", "-x", "-k", str(archive), str(expanded)])
        verify_app(expanded / "微迹.app", tag)
        stage = pathlib.Path(temporary) / "disk"
        stage.mkdir()
        run(["ditto", str(app), str(stage / "微迹.app")])
        (stage / "Applications").symlink_to("/Applications", target_is_directory=True)
        (stage / "安装说明.txt").write_text(
            "本版本仅支持 Apple Silicon（arm64）Mac，要求 macOS 14 或更新版本。\n"
            "将微迹拖入 Applications。系统要求时，在隐私与安全性中允许打开，再按应用引导授予完全磁盘访问。\n"
            "本版本使用固定项目证书签名，尚未经过 Apple Developer ID 公证。\n"
            "从之前的本机签名构建切换时，需要重新添加一次权限。保留原安装路径可避免两份应用并存。\n"
            "应用只归档系统通知，不代表完整聊天记录。\n", encoding="utf-8")
        image = output / asset_names(version)[1]
        run(["hdiutil", "create", "-volname", f"微迹 {version}", "-srcfolder", str(stage), "-format", "UDZO", str(image)])
        run(["hdiutil", "verify", str(image)])
    manifest = {
        "version": version, "build": info["CFBundleVersion"], "tag": tag,
        "commit": run(["git", "rev-parse", "HEAD"]), "architectures": architectures,
        "minimum_macos": info["LSMinimumSystemVersion"], "bundle_id": info["CFBundleIdentifier"],
        "certificate_sha1": fingerprint.upper(), "notarized": False,
        "sha256": {p.name: file_hash(p) for p in sorted(output.iterdir())},
    }
    (output / "release-manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
    checksums = "".join(f"{file_hash(p)}  {p.name}\n" for p in sorted(output.iterdir()))
    (output / "SHA256SUMS").write_text(checksums)
    notes = f"""微迹 {version} · macOS 14+ · Apple Silicon（arm64）

下载 DMG 后将应用拖入 Applications，或解压 ZIP 安装。首次打开按系统提示和应用引导授予权限。

- 从 v0.4.1 起仅发布 Apple Silicon（arm64）版本；之前已发布的通用包保留原样。
- 新增 Agent 主动提醒：HTTP POST `/api/reminders` 与 MCP `wechat_create_reminder`，由微迹展示角落卡片并保存到收件箱，无需固定匹配规则。
- HTTP 提醒接口使用本机令牌；请求持久化、事件去重并保留来源消息引用。MCP 明确提示 agent 由微迹负责提醒，不以聊天回复代替。
- 侧栏统一为“API 与 Agent”，权限启动页也可查看接口；定时查阅与语义判断由外部 agent 调度器负责。
- 原生通知档案、文件/图片索引、启动权限引导和微信风格绿色界面。
- 提醒规则支持 iCloud Drive 文件夹同步：各设备选择同一文件夹，自动合并独立修改、同步删除，并保留停用的冲突副本。默认关闭，仅同步规则，不含消息和收件箱。
- 持久化提醒收件箱：未处理、稍后、已处理状态及计时重启后恢复；支持逐条处理及恢复。
- 从消息快捷创建会话、发送者和 @所有人规则，预填条件及测试样例，确认保存后生效。
- 每条规则支持本地安静时段及同一会话合并间隔，MCP 支持配置，旧规则和客户端保持兼容。
- 多维提醒规则：发送者、会话/频道、内容及会话类型，支持正则、排除项和“且/或”组合；默认无声角落浮窗、不抢输入，支持收起、合并及稍后提醒。
- MCP 可按用户要求查看、测试、保存和删除提醒规则；带版本冲突保护，通知与文件工具保持只读。
- 启动、权限和设置窗口具有明确的尺寸下限，修复窗口缩成小条、正文及按钮裁切的问题。
- 应用启动即提供本机 HTTP MCP，默认 http://127.0.0.1:18765/mcp；原有 stdio 接口保留。
- 固定 CI 项目证书签名；未使用 Apple Developer ID，尚未公证。首次打开可能需要在系统设置的“隐私与安全性”中允许。
- 从原本机证书构建切换到此 CI 证书构建，需要重新添加一次完全磁盘访问。档案目录和 Bundle ID 保持兼容。
- 通知档案不等于完整聊天历史，文件及图片的消息归属仍须核对。

`SHA256SUMS` 可校验下载文件；`release-manifest.json` 记录提交、版本、arm64 架构与证书指纹。
"""
    (ROOT / "dist/release-notes.md").write_text(notes)
    print(f"Packaged and verified {version}: ZIP, DMG, manifest and checksums.")


def verified_assets(directory, version):
    paths = [directory / name for name in asset_names(version)]
    if not all(p.is_file() and p.stat().st_size > 0 for p in paths):
        raise ValueError("Complete release assets are required before publishing.")
    expected = {p.name for p in paths if p.name != "SHA256SUMS"}
    entries = {}
    for line in (directory / "SHA256SUMS").read_text().splitlines():
        checksum, name = line.split("  ", 1)
        if name in entries or name not in expected or not re.fullmatch(r"[a-f0-9]{64}", checksum):
            raise ValueError("Invalid release checksum entries.")
        entries[name] = checksum
    if set(entries) != expected or any(file_hash(directory / name) != checksum for name, checksum in entries.items()):
        raise ValueError("Release checksums do not match the complete asset set.")
    manifest = json.loads((directory / "release-manifest.json").read_text())
    if manifest["version"] != version or manifest["tag"] != f"v{version}":
        raise ValueError("Release manifest version does not match its tag.")
    return paths


def publish(tag):
    version = validate(tag)
    paths = verified_assets(ROOT / "dist/release", version)
    # Exact-tag lookup distinguishes absence from authentication/network errors.
    releases = json.loads(run(["gh", "api", "--paginate", "--slurp", "repos/{owner}/{repo}/releases?per_page=100"]))
    existing = [item for page in releases for item in page if item["tag_name"] == tag]
    if existing and not existing[0]["draft"]:
        raise ValueError("Published release already exists; refusing to replace its assets.")
    if not existing:
        run(["gh", "release", "create", tag, "--verify-tag", "--draft", "--title", tag,
             "--notes-file", str(ROOT / "dist/release-notes.md")])
    run(["gh", "release", "upload", tag, *map(str, paths), "--clobber"])
    remote = json.loads(run(["gh", "release", "view", tag, "--json", "assets"]))
    if {item["name"]: item["size"] for item in remote["assets"]} != {p.name: p.stat().st_size for p in paths}:
        raise ValueError("Uploaded draft assets differ from the verified release files.")
    run(["gh", "release", "edit", tag, "--title", tag, "--draft=false", "--latest"])
    print(run(["gh", "release", "view", tag, "--json", "url", "--jq", ".url"]))


def verify_published(tag):
    if not re.fullmatch("v" + SEMVER, tag):
        raise ValueError("Expected a stable release tag such as v0.1.0.")
    version = tag[1:]
    metadata = json.loads(run(["gh", "release", "view", tag, "--json", "isDraft,url"]))
    if metadata["isDraft"]:
        raise ValueError("Release is still a draft.")
    with tempfile.TemporaryDirectory(prefix="weiji-published-verify-") as temporary:
        root = pathlib.Path(temporary)
        run(["gh", "release", "download", tag, "--dir", str(root)])
        verified_assets(root, version)
        manifest = json.loads((root / "release-manifest.json").read_text())
        if manifest["commit"] != run(["git", "rev-list", "-n", "1", tag]):
            raise ValueError("Published manifest does not identify the tagged source commit.")
        expanded = root / "expanded"
        run(["ditto", "-x", "-k", str(root / asset_names(version)[0]), str(expanded)])
        info, architectures, fingerprint = verify_app(expanded / "微迹.app", tag, match_source=False)
        if (manifest["build"] != info["CFBundleVersion"] or manifest["architectures"] != architectures
                or manifest["certificate_sha1"] != fingerprint.upper()):
            raise ValueError("Published manifest does not match its signed application.")
        for name, expected in manifest["sha256"].items():
            if name not in set(asset_names(version)[:2]) or file_hash(root / name) != expected:
                raise ValueError("Published manifest contains invalid asset checksums.")
        run(["hdiutil", "verify", str(root / asset_names(version)[1])])
    print(f"Verified published assets, tagged source, version, architectures, pinned signature and DMG: {metadata['url']}")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=["validate", "package", "publish", "verify"])
    parser.add_argument("--tag")
    options = parser.parse_args()
    if options.action != "validate" and not options.tag:
        parser.error("--tag is required for packaging and publishing")
    if options.action == "validate":
        print(validate(options.tag))
    elif options.action == "package":
        package(options.tag)
    elif options.action == "publish":
        publish(options.tag)
    else:
        verify_published(options.tag)
