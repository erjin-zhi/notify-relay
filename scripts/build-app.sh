#!/bin/bash
# 编译并打包成 build/SendWord.app（沙盒应用，临时签名）。
# 想用自己的证书签名：SIGN_IDENTITY="Apple Development: xxx" scripts/build-app.sh
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release --product SendWord
BIN="$(swift build -c release --show-bin-path)/SendWord"

# 项目目录由文件同步服务管理，刚生成的文件会被加上 Finder 附加信息，导致签名失败。
# 所以先在临时目录里组装、签名，签好后再复制回 build/。
STAGE="$(mktemp -d "${TMPDIR:-/tmp}/send-word-build.XXXXXX")"
trap 'rm -rf "$STAGE"' EXIT
APP="$STAGE/SendWord.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

# SwiftPM 会把最低系统版本当成 SDK 版本写进二进制，系统据此让 App 用旧外观运行。
# 改成实际编译用的 SDK 版本，界面才会是当前系统的 Liquid Glass 风格。
SDK_VERSION="$(xcrun --show-sdk-version)"
MIN_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' Resources/Info.plist)"
vtool -set-build-version macos "$MIN_VERSION" "$SDK_VERSION" -replace -output "$APP/Contents/MacOS/SendWord" "$BIN"
cp Resources/Info.plist "$APP/Contents/Info.plist"
swift scripts/make-icon.swift "$APP/Contents/Resources/AppIcon.icns"

# 更新功能用的 Sparkle.framework 放进 Contents/Frameworks，并让可执行文件到那里找它。
mkdir -p "$APP/Contents/Frameworks"
ditto "$(dirname "$BIN")/Sparkle.framework" "$APP/Contents/Frameworks/Sparkle.framework"
install_name_tool -add_rpath @executable_path/../Frameworks "$APP/Contents/MacOS/SendWord"

xattr -cr "$APP"
IDENTITY="${SIGN_IDENTITY:--}"
# 从里到外签名：Sparkle 自带的 XPC 服务和辅助程序 → 框架 → App。
# 框架要和 App 用同一个身份重新签名，否则开启强化运行时后系统会拒绝加载它。
SPARKLE="$APP/Contents/Frameworks/Sparkle.framework/Versions/B"
codesign --force --options runtime --sign "$IDENTITY" "$SPARKLE/XPCServices/Installer.xpc"
codesign --force --options runtime --preserve-metadata=entitlements --sign "$IDENTITY" "$SPARKLE/XPCServices/Downloader.xpc"
codesign --force --options runtime --sign "$IDENTITY" "$SPARKLE/Autoupdate"
codesign --force --options runtime --sign "$IDENTITY" "$SPARKLE/Updater.app"
codesign --force --options runtime --sign "$IDENTITY" "$APP/Contents/Frameworks/Sparkle.framework"
# 临时签名没有 Team ID，强化运行时的库校验会拒绝加载 Sparkle.framework（即使它也是临时签名）。
# 只有临时签名时才关闭库校验；用正式证书签名时框架和 App 的 Team ID 一致，不需要。
ENTITLEMENTS="$STAGE/SendWord.entitlements"
cp Resources/SendWord.entitlements "$ENTITLEMENTS"
if [ "$IDENTITY" = "-" ]; then
    /usr/libexec/PlistBuddy -c 'Add :com.apple.security.cs.disable-library-validation bool true' "$ENTITLEMENTS"
fi
codesign --force --options runtime --entitlements "$ENTITLEMENTS" --sign "$IDENTITY" "$APP"
codesign --verify --strict "$APP"

mkdir -p build
rm -rf build/SendWord.app
ditto "$APP" build/SendWord.app
# 同步服务会自动重加 FinderInfo；严格校验已在临时目录执行，这里验证最终资源签名。
codesign --verify build/SendWord.app
echo "已生成 build/SendWord.app"
