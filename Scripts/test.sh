#!/bin/bash
set -euo pipefail
PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_ROOT"

TEST_OPTIONS=(--disable-xctest --enable-swift-testing)
DEVELOPER_PATH="$(xcode-select -p)"
TEST_FRAMEWORKS="$DEVELOPER_PATH/Library/Developer/Frameworks"

# Command Line Tools includes Swift Testing but SwiftPM does not add its framework search path.
# Full Xcode configures these paths itself. Keep the workaround confined to the test command.
if [[ "$DEVELOPER_PATH" == */CommandLineTools && -d "$TEST_FRAMEWORKS/Testing.framework" ]]; then
    TEST_OPTIONS+=(-Xswiftc -F -Xswiftc "$TEST_FRAMEWORKS" -Xlinker -rpath -Xlinker "$TEST_FRAMEWORKS")
    # CLT omits the Swift module for Testing's optional Foundation cross-import overlay.
    TEST_OPTIONS+=(-Xswiftc -Xfrontend -Xswiftc -disable-cross-import-overlays)
fi

exec swift test "${TEST_OPTIONS[@]}" "$@"
