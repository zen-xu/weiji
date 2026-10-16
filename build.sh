#!/bin/bash
set -euo pipefail
PROJECT_ROOT="$(cd "$(dirname "$0")" && pwd)"
APP_BUNDLE="$PROJECT_ROOT/dist/微迹.app"
cd "$PROJECT_ROOT"

BUILD_OPTIONS=(--configuration release --product WeChatListener)
if [[ "${1:-}" == "--universal" && $# -eq 1 ]]; then
    # Build each slice with SwiftPM's native driver, then combine before signing.
    # This also works with Command Line Tools; multi-arch xcbuild requires full Xcode.
    UNIVERSAL=true
elif [[ $# -ne 0 ]]; then
    printf '用法：bash build.sh [--universal]\n' >&2
    exit 2
else
    UNIVERSAL=false
fi

python3 Scripts/sign_app.py --check
if $UNIVERSAL; then
    BINARIES=()
    for ARCHITECTURE in arm64 x86_64; do
        OPTIONS=("${BUILD_OPTIONS[@]}" --arch "$ARCHITECTURE" --scratch-path ".build/universal-$ARCHITECTURE")
        swift build "${OPTIONS[@]}"
        BINARY_DIRECTORY="$(swift build "${OPTIONS[@]}" --show-bin-path)"
        BINARIES+=("$BINARY_DIRECTORY/WeChatListener")
    done
    mkdir -p .build/universal
    lipo -create "${BINARIES[@]}" -output .build/universal/WeChatListener
    BINARY_DIRECTORY="$PROJECT_ROOT/.build/universal"
else
    swift build "${BUILD_OPTIONS[@]}"
    BINARY_DIRECTORY="$(swift build "${BUILD_OPTIONS[@]}" --show-bin-path)"
fi

mkdir -p "$APP_BUNDLE/Contents/MacOS" "$APP_BUNDLE/Contents/Resources"
cp "$BINARY_DIRECTORY/WeChatListener" "$APP_BUNDLE/Contents/MacOS/WeChatListener"
cp Resources/AppIcon.icns "$APP_BUNDLE/Contents/Resources/AppIcon.icns"
cp Resources/Info.plist "$APP_BUNDLE/Contents/Info.plist"
python3 Scripts/sign_app.py "$APP_BUNDLE"
printf '已打包并验证签名：%s\n' "$APP_BUNDLE"
