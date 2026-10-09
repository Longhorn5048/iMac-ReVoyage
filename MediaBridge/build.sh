#!/bin/sh
set -eu
root="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
app="$1"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
ditto "$root/TargetBridge-Shared/Languages" "$app/Contents/Resources/Languages"
clang -O2 -Wall -Wextra -fobjc-arc -arch x86_64 -mmacosx-version-min=10.15 \
  "$root/MediaBridge/main.m" -framework AppKit -framework AVFoundation -framework CoreImage \
  -framework CoreMedia -framework CoreVideo -framework ImageIO -o "$app/Contents/MacOS/ReVoyageMediaBridge"
/usr/bin/python3 - "$app" <<'PY'
import plistlib,sys
from pathlib import Path
info={'CFBundleIdentifier':'re.voyage.media-bridge','CFBundleName':'iMac ReVoyage Media Bridge',
 'CFBundleExecutable':'ReVoyageMediaBridge','CFBundlePackageType':'APPL','CFBundleVersion':'1','CFBundleShortVersionString':'1.0',
 'LSMinimumSystemVersion':'10.15','LSUIElement':True,
 'NSCameraUsageDescription':'Share this iMac camera with the connected Mac only when requested.',
 'NSMicrophoneUsageDescription':'Share this iMac microphone with the connected Mac only when requested.'}
(Path(sys.argv[1])/'Contents/Info.plist').write_bytes(plistlib.dumps(info))
PY
codesign --force --sign - "$app"
