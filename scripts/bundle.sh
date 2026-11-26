#!/bin/bash
# 編譯並打包成 build/ChronoPlay.app。
#   scripts/bundle.sh            # release 版
#   scripts/bundle.sh debug      # debug 版
# 只用 Command Line Tools，不需要 Xcode；產物都在專案資料夾內的 .build/ 和 build/。
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="${1:-release}"
APP="build/ChronoPlay.app"

swift build -c "$CONFIG" --product ChronoPlay
BIN_DIR="$(swift build -c "$CONFIG" --show-bin-path)"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/ChronoPlay" "$APP/Contents/MacOS/ChronoPlay"
cp Resources/Info.plist "$APP/Contents/Info.plist"

# ad-hoc 簽章（不需要 Apple Developer 帳號），macOS 才允許執行並使用 Keychain
codesign --force --sign - "$APP"

echo "完成：$APP"
echo "執行：open $APP"
