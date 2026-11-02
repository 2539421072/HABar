#!/bin/bash
# 构建 HA 面板.app
set -e
cd "$(dirname "$0")"

APP_NAME="HA 面板"
APP="${APP_NAME}.app"
EXE="HABar"

echo "==> 清理"
rm -rf "$APP" build
mkdir -p build "$APP/Contents/MacOS" "$APP/Contents/Resources"

echo "==> 编译"
clang -fobjc-arc -O2 -mmacosx-version-min=14.0 \
  -framework Cocoa -framework WebKit \
  main.m HAClient.m -o "$APP/Contents/MacOS/$EXE"

echo "==> 拷贝前端资源"
cp web/index.html web/styles.css web/app.js "$APP/Contents/Resources/"

echo "==> 生成图标"
if [ -f icon.html ]; then
  rm -rf build/AppIcon.iconset
  mkdir -p build/AppIcon.iconset
  "$APP/Contents/MacOS/$EXE" --snapshot build/icon.png --html "$(pwd)/icon.html" --size 1024x1024 --delay 1.6 >/dev/null 2>&1 || true
  SRC="build/icon.png"
  if [ -f "$SRC" ]; then
    for s in 16 32 64 128 256 512 1024; do
      sips -z $s $s "$SRC" --out "build/AppIcon.iconset/icon_${s}x${s}.png" >/dev/null
    done
    cp "build/AppIcon.iconset/icon_32x32.png"     "build/AppIcon.iconset/icon_16x16@2x.png"
    cp "build/AppIcon.iconset/icon_64x64.png"     "build/AppIcon.iconset/icon_32x32@2x.png"
    cp "build/AppIcon.iconset/icon_256x256.png"   "build/AppIcon.iconset/icon_128x128@2x.png"
    cp "build/AppIcon.iconset/icon_512x512.png"   "build/AppIcon.iconset/icon_256x256@2x.png"
    cp "build/AppIcon.iconset/icon_1024x1024.png" "build/AppIcon.iconset/icon_512x512@2x.png"
    rm -f "build/AppIcon.iconset/icon_64x64.png" "build/AppIcon.iconset/icon_1024x1024.png"
    iconutil -c icns build/AppIcon.iconset -o "$APP/Contents/Resources/AppIcon.icns" && echo "    图标已生成"
  else
    echo "    跳过图标（渲染失败）"
  fi
fi

echo "==> 写入 Info.plist"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>HA 面板</string>
  <key>CFBundleDisplayName</key><string>HA 面板</string>
  <key>CFBundleIdentifier</key><string>cn.local.habar</string>
  <key>CFBundleExecutable</key><string>HABar</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSLocalNetworkUsageDescription</key><string>用于连接局域网内的 Home Assistant 服务器。</string>
  <key>NSAppTransportSecurity</key>
  <dict>
    <key>NSAllowsArbitraryLoads</key><true/>
    <key>NSAllowsLocalNetworking</key><true/>
  </dict>
</dict>
</plist>
PLIST

echo "==> 签名"
codesign --force --deep --sign - "$APP" 2>/dev/null || echo "    签名跳过"

echo "==> 完成: $(pwd)/$APP"
