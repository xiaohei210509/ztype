#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
swift test --disable-xctest --scratch-path "${ZTYPE_BUILD_DIR:-$HOME/Library/Caches/ztype/Build}"
