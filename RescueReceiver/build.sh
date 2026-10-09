#!/bin/zsh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="${RESCUE_APP_DIR:-$ROOT/build/iMac ReVoyage Rescue.app}"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"

xcrun clang -arch x86_64 -mmacosx-version-min=10.15 -fobjc-arc -O2 \
  -Werror=unguarded-availability-new \
  -framework AppKit -framework AVFoundation -framework CoreGraphics \
  -framework CoreFoundation -framework IOKit \
  "$ROOT/RescueReceiver/main.m" "$ROOT/RescueReceiver/DisplaySignalState.c" \
  -o "$APP/Contents/MacOS/RescueReceiver"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>re.voyage.rescue</string>
<key>CFBundleName</key><string>iMac ReVoyage Rescue</string>
<key>CFBundleExecutable</key><string>RescueReceiver</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.1.1</string>
<key>CFBundleVersion</key><string>2</string>
<key>LSMinimumSystemVersion</key><string>10.15</string>
<key>LSUIElement</key><true/>
<key>NSCameraUsageDescription</key><string>接收 HDMI/UVC 救援画面。</string>
<key>NSMicrophoneUsageDescription</key><string>播放 HDMI/UAC 救援声音。</string>
</dict></plist>
PLIST
xattr -cr "$APP"
codesign --force --sign - "$APP"
echo "$APP"
