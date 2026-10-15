#!/bin/bash
set -euo pipefail
TASK_ROOT="$(cd "$(dirname "$0")" && pwd)"
TASK_ARCH="$(uname -m)"
TASK_APP="$TASK_ROOT/dist/微信消息监听.app"
mkdir -p "$TASK_ROOT/build/module-cache" "$TASK_APP/Contents/MacOS" "$TASK_APP/Contents/Resources"
swiftc -O -swift-version 5 -target "$TASK_ARCH-apple-macos14.0" \
  -module-cache-path "$TASK_ROOT/build/module-cache" \
  "$TASK_ROOT"/Sources/*.swift "$TASK_ROOT"/Tests/*.swift \
  -framework AppKit -framework SwiftUI -framework CryptoKit -framework VideoToolbox -framework CoreImage -framework ImageIO -framework CoreServices -lsqlite3 \
  -o "$TASK_APP/Contents/MacOS/WeChatListener"
cp "$TASK_ROOT/Resources/AppIcon.icns" "$TASK_APP/Contents/Resources/AppIcon.icns"
cp "$TASK_ROOT/Resources/Info.plist" "$TASK_APP/Contents/Info.plist"
codesign --force --sign - "$TASK_APP"
codesign --verify --strict --verbose=2 "$TASK_APP"
"$TASK_APP/Contents/MacOS/WeChatListener" --self-test
printf '已构建并验证：%s\n' "$TASK_APP"
