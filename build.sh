#!/bin/bash
# 构建 ServerMonitor.app 并打包 DMG
# 用法：./build.sh [版本号]   例如 ./build.sh 1.0.0
set -euo pipefail
cd "$(dirname "$0")"

VERSION="${1:-1.0.0}"
APP="ServerMonitor.app"
BUNDLE_ID="local.servermonitor"
OUT="build"
rm -rf "$OUT/$APP" "$OUT/dmg" "$OUT/ServerMonitor-${VERSION}.dmg"
mkdir -p "$OUT/$APP/Contents/MacOS"
mkdir -p "$OUT/$APP/Contents/Resources"

echo "▶ 编译中…"
swiftc -O -swift-version 5 \
  -o "$OUT/$APP/Contents/MacOS/ServerMonitor" \
  main.swift

# 菜单栏应用：不在 Dock 显示图标
cat > "$OUT/$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>ServerMonitor</string>
    <key>CFBundleIdentifier</key><string>${BUNDLE_ID}</string>
    <key>CFBundleShortVersionString</key><string>${VERSION}</string>
    <key>CFBundleVersion</key><string>${VERSION}</string>
    <key>CFBundleExecutable</key><string>ServerMonitor</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>LSMinimumSystemVersion</key><string>12.0</string>
    <key>LSUIElement</key><true/>
</dict>
</plist>
PLIST

# 把当前 config.json 打包进 Resources（运行时优先读 app 同目录/旁边的 config.json）
cp config.json "$OUT/$APP/Contents/Resources/config.json"

echo "▶ Ad-hoc 签名（本机分发足够；对外分发请替换为 Developer ID）"
codesign --force --sign - "$OUT/$APP"

echo "▶ 组装 DMG…"
STAGE="$OUT/dmg"
mkdir -p "$STAGE"
cp -R "$OUT/$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create \
  -volname "ServerMonitor ${VERSION}" \
  -srcfolder "$STAGE" \
  -ov -format UDZO \
  "$OUT/ServerMonitor-${VERSION}.dmg" \
  -quiet
rm -rf "$STAGE"

# 校验 DMG 可正常挂载
hdiutil verify "$OUT/ServerMonitor-${VERSION}.dmg" -quiet

echo "✅ 构建完成：$PWD/$OUT/$APP"
echo "   DMG 产物：$PWD/$OUT/ServerMonitor-${VERSION}.dmg"
echo "   安装：打开 DMG，把 ServerMonitor 拖入 Applications 文件夹"
