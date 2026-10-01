#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
export CLANG_MODULE_CACHE_PATH="$PWD/.build/module-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build/module-cache"
SWIFT_COMPILER="$(xcrun --find swiftc)"
TEST_PLUGIN="$(dirname "$SWIFT_COMPILER")/../lib/swift/host/plugins/testing/libTestingMacros.dylib"
EXTRA=()
if [[ -f "$TEST_PLUGIN" ]]; then
  EXTRA=(-Xswiftc -load-plugin-library -Xswiftc "$TEST_PLUGIN")
fi
swift test --disable-sandbox --disable-xctest -debug-info-format none "${EXTRA[@]}" "$@"
