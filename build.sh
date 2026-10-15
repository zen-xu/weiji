#!/bin/bash
set -euo pipefail
PROJECT_ROOT="$(cd "$(dirname "$0")" && pwd)"
APP_BUNDLE="$PROJECT_ROOT/dist/微信消息监听.app"
cd "$PROJECT_ROOT"

python3 Scripts/sign_app.py --check
swift build --configuration release --product WeChatListener
BINARY_DIRECTORY="$(swift build --configuration release --show-bin-path)"

mkdir -p "$APP_BUNDLE/Contents/MacOS" "$APP_BUNDLE/Contents/Resources"
cp "$BINARY_DIRECTORY/WeChatListener" "$APP_BUNDLE/Contents/MacOS/WeChatListener"
cp Resources/AppIcon.icns "$APP_BUNDLE/Contents/Resources/AppIcon.icns"
cp Resources/Info.plist "$APP_BUNDLE/Contents/Info.plist"
python3 Scripts/sign_app.py "$APP_BUNDLE"
printf '已打包并验证签名：%s\n' "$APP_BUNDLE"
