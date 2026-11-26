#!/bin/bash
# 編譯並打包成 build/ChronoPlay.app。
#   scripts/bundle.sh            # release 版
#   scripts/bundle.sh debug      # debug 版
#   CHRONOPLAY_STABLE_SIGNING=1 scripts/bundle.sh   # 開發用：固定簽章身分（見下方說明）
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

# ad-hoc 簽章（不需要 Apple Developer 帳號），macOS 才允許執行並使用 Keychain。
# 預設用 cdhash 當簽章身分：Keychain 的「永遠允許」只認這一份執行檔，
# 別的程式無法冒充 ChronoPlay 讀取 token；代價是每次重新編譯後第一次讀取都會再問一次。
#
# CHRONOPLAY_STABLE_SIGNING=1 時改把身分固定成 bundle id，重新編譯就不會再問，
# 但任何用同一個 bundle id 做 ad-hoc 簽章的程式都能讀到 token，只在自己的開發機上用。
BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' Resources/Info.plist)"
if [[ "${CHRONOPLAY_STABLE_SIGNING:-0}" == "1" ]]; then
  echo "警告：使用固定簽章身分（$BUNDLE_ID），其他程式可冒充此身分讀取 Keychain 裡的 token。" >&2
  codesign --force --sign - -r="designated => identifier \"$BUNDLE_ID\"" "$APP"
else
  codesign --force --sign - --identifier "$BUNDLE_ID" "$APP"
fi

echo "完成：$APP"
echo "執行：open $APP"
