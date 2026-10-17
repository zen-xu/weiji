#!/bin/bash
set -euo pipefail
PROJECT_ROOT="$(cd "$(dirname "$0")" && pwd)"
APP_BUNDLE="$PROJECT_ROOT/dist/微迹.app"
cd "$PROJECT_ROOT"

if [[ $# -ne 0 ]]; then
    printf '用法：bash build.sh（仅构建 Apple Silicon arm64）\n' >&2
    exit 2
fi

BUILD_OPTIONS=(--configuration release --product WeChatListener --arch arm64)
python3 Scripts/sign_app.py --check
swift build "${BUILD_OPTIONS[@]}"
BINARY_DIRECTORY="$(swift build "${BUILD_OPTIONS[@]}" --show-bin-path)"
if [[ "$(lipo -archs "$BINARY_DIRECTORY/WeChatListener")" != "arm64" ]]; then
    printf '构建产物必须仅包含 arm64 架构。\n' >&2
    exit 1
fi

mkdir -p "$APP_BUNDLE/Contents/MacOS" "$APP_BUNDLE/Contents/Resources"
cp "$BINARY_DIRECTORY/WeChatListener" "$APP_BUNDLE/Contents/MacOS/WeChatListener"
cp Resources/AppIcon.icns "$APP_BUNDLE/Contents/Resources/AppIcon.icns"
cp Resources/Info.plist "$APP_BUNDLE/Contents/Info.plist"
python3 Scripts/sign_app.py "$APP_BUNDLE"
printf '已打包并验证签名：%s\n' "$APP_BUNDLE"
