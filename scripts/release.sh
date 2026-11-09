#!/bin/bash
# 发布新版本：改版本号 → 打包签名 → 压缩 → 用 Sparkle 私钥签名 → 生成 appcast.xml。
#
#   scripts/release.sh 0.2.0                 # 只生成文件，放在 build/release/
#   scripts/release.sh 0.2.0 --publish       # 同时创建 GitHub Release 并上传
#
# 更新说明写在 build/release/notes-<版本>.md（Markdown），没有就用“修复问题，改进体验”。
# App 每天读取 https://github.com/erjin-zhi/send-word/releases/latest/download/appcast.xml，
# 所以每个 Release 都要带上 appcast.xml 和对应的 zip。
#
# 签名私钥沿用本机钥匙串中的历史账户 notify-relay，确保旧版本能验证更新。
# 换电脑前先导出备份：.build/artifacts/sparkle/Sparkle/bin/generate_keys --account notify-relay -x 私钥文件
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:?用法：scripts/release.sh <版本号，如 0.2.0> [--publish]}"
PUBLISH="${2:-}"
REPO="erjin-zhi/send-word"
TAG="v$VERSION"
PLIST=Resources/Info.plist
PB=/usr/libexec/PlistBuddy
SPARKLE_BIN=.build/artifacts/sparkle/Sparkle/bin
# 测试时可以换成本地地址，例如 DOWNLOAD_URL_PREFIX=http://localhost:8000/
URL_PREFIX="${DOWNLOAD_URL_PREFIX:-https://github.com/$REPO/releases/download/$TAG/}"

# Sparkle 用 CFBundleVersion 判断新旧，每次发布加一。
BUILD=$(( $($PB -c 'Print :CFBundleVersion' "$PLIST") + 1 ))
$PB -c "Set :CFBundleShortVersionString $VERSION" "$PLIST"
$PB -c "Set :CFBundleVersion $BUILD" "$PLIST"
MIN_SYSTEM="$($PB -c 'Print :LSMinimumSystemVersion' "$PLIST")"

swift package resolve >/dev/null
./scripts/build-app.sh

OUT=build/release
mkdir -p "$OUT"
ZIP_NAME="send-word-$VERSION.zip"
ZIP="$OUT/$ZIP_NAME"
rm -f "$ZIP"
# 不打包扩展属性：同步服务加的 Finder 信息会让解压后的 App 签名校验失败。
ditto -c -k --norsrc --noextattr --keepParent build/SendWord.app "$ZIP"

SIGNATURE="$("$SPARKLE_BIN/sign_update" --account notify-relay "$ZIP")"

NOTES_FILE="$OUT/notes-$VERSION.md"
[ -f "$NOTES_FILE" ] || printf -- '- 修复问题，改进体验\n' > "$NOTES_FILE"

cat > "$OUT/appcast.xml" <<XML
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>捎信 SendWord</title>
    <link>https://github.com/$REPO</link>
    <item>
      <title>$VERSION</title>
      <pubDate>$(LC_ALL=C date -u '+%a, %d %b %Y %H:%M:%S +0000')</pubDate>
      <sparkle:version>$BUILD</sparkle:version>
      <sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>$MIN_SYSTEM</sparkle:minimumSystemVersion>
      <sparkle:fullReleaseNotesLink>https://github.com/$REPO/releases/tag/$TAG</sparkle:fullReleaseNotesLink>
      <description sparkle:format="markdown"><![CDATA[
$(cat "$NOTES_FILE")
]]></description>
      <enclosure url="$URL_PREFIX$ZIP_NAME" $SIGNATURE type="application/octet-stream"/>
    </item>
  </channel>
</rss>
XML

echo "已生成 ${ZIP} 和 ${OUT}/appcast.xml（版本 ${VERSION}，构建号 ${BUILD}）"

if [ "$PUBLISH" = "--publish" ]; then
    gh release create "$TAG" "$ZIP" "$OUT/appcast.xml" \
        --repo "$REPO" --title "捎信 SendWord $VERSION" --notes-file "$NOTES_FILE"
else
    echo "检查无误后发布：gh release create $TAG $ZIP $OUT/appcast.xml --repo $REPO --title \"捎信 SendWord $VERSION\" --notes-file $NOTES_FILE"
fi
