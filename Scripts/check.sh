#!/bin/bash
set -euo pipefail
PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_ROOT"

bash Scripts/format.sh --check
bash Scripts/test.sh
python3 -B Tests/Integration/test_signing_config.py
python3 -B Tests/Integration/test_release_config.py
BINARY_DIRECTORY="$(swift build --show-bin-path)"
python3 -B Tests/Integration/test_mcp_queries.py "$BINARY_DIRECTORY/WeChatListener"
python3 -B Tests/Integration/test_mcp_stdio.py "$BINARY_DIRECTORY/WeChatListener"
python3 -B Tests/Integration/test_mcp_http.py "$BINARY_DIRECTORY/WeChatListener"
python3 -B Tests/Integration/test_mcp_stdio.py "$BINARY_DIRECTORY/WeChatListener" --http
