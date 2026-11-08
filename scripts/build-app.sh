#!/bin/bash
# 编译并打包成 build/notify-relay.app（沙盒应用，临时签名）。
# 想用自己的证书签名：SIGN_IDENTITY="Apple Development: xxx" scripts/build-app.sh
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release --product NotifyRelay
BIN="$(swift build -c release --show-bin-path)/NotifyRelay"

# 项目目录由文件同步服务管理，刚生成的文件会被加上 Finder 附加信息，导致签名失败。
# 所以先在临时目录里组装、签名，签好后再复制回 build/。
STAGE="$(mktemp -d "${TMPDIR:-/tmp}/notify-relay-build.XXXXXX")"
trap 'rm -rf "$STAGE"' EXIT
APP="$STAGE/notify-relay.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

# SwiftPM 会把最低系统版本当成 SDK 版本写进二进制，系统据此让 App 用旧外观运行。
# 改成实际编译用的 SDK 版本，界面才会是当前系统的 Liquid Glass 风格。
SDK_VERSION="$(xcrun --show-sdk-version)"
MIN_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' Resources/Info.plist)"
vtool -set-build-version macos "$MIN_VERSION" "$SDK_VERSION" -replace -output "$APP/Contents/MacOS/NotifyRelay" "$BIN"
cp Resources/Info.plist "$APP/Contents/Info.plist"
swift scripts/make-icon.swift "$APP/Contents/Resources/AppIcon.icns"

xattr -cr "$APP"
codesign --force --options runtime --entitlements Resources/NotifyRelay.entitlements --sign "${SIGN_IDENTITY:--}" "$APP"
codesign --verify --strict "$APP"

mkdir -p build
rm -rf build/notify-relay.app
ditto "$APP" build/notify-relay.app
# 同步服务会自动重加 FinderInfo；严格校验已在临时目录执行，这里验证最终资源签名。
codesign --verify build/notify-relay.app
echo "已生成 build/notify-relay.app"
