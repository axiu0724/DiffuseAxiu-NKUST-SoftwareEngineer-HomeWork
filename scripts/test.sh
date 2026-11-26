#!/bin/bash
# 執行單元測試。
# 只有 Command Line Tools（沒有 Xcode）時，swift test 找不到 Swift Testing 的 macro plugin，
# 所以這裡自動補上 plugin 路徑。其他參數會原樣轉給 swift test，例如：
#   scripts/test.sh --filter SequencePlanTests
set -euo pipefail
cd "$(dirname "$0")/.."

TOOLCHAIN_USR="$(dirname "$(dirname "$(xcrun --find swift)")")"
PLUGIN_DIR="$TOOLCHAIN_USR/lib/swift/host/plugins/testing"

EXTRA=()
if [[ -d "$PLUGIN_DIR" ]]; then
  EXTRA=(-Xswiftc -plugin-path -Xswiftc "$PLUGIN_DIR")
fi

swift test "${EXTRA[@]}" "$@"
