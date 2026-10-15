#!/bin/bash
set -euo pipefail
PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_ROOT"

if [[ "${1:-}" == "--check" ]]; then
    exec xcrun swift-format lint --strict --recursive Package.swift Sources Tests
fi
exec xcrun swift-format format --in-place --recursive Package.swift Sources Tests
