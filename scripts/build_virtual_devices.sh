#!/bin/sh
set -eu
root="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
app="$1"
architectures="$2"
team="${DEVELOPMENT_TEAM:-}"
case "$team" in *[!A-Z0-9]*) echo "Invalid signing team" >&2; exit 64 ;; esac
test -z "$team" || test "${#team}" -eq 10
work="$(mktemp -d "${TMPDIR:-/tmp}/revoyage-devices-build.XXXXXX")"
trap 'rm -rf "$work"' EXIT HUP INT TERM
camera="$app/Contents/Library/SystemExtensions/com.targetbridge.sender.camera.systemextension"
microphone="$app/Contents/Resources/ReVoyageMicrophone.driver"
speaker="$app/Contents/Resources/ReVoyageSpeaker.driver"
mkdir -p "$camera/Contents/MacOS" "$microphone/Contents/MacOS" "$speaker/Contents/MacOS" "$app/Contents/MacOS"
for architecture in $architectures; do
  case "$architecture" in arm64|x86_64) ;; *) exit 64 ;; esac
  clang -O2 -Wall -Wextra -fobjc-arc -arch "$architecture" -mmacosx-version-min=14.0 \
    "$root/VirtualDevices/Camera/main.m" -framework Foundation -framework CoreMediaIO \
    -framework CoreMedia -framework CoreVideo -framework CoreAudio -framework Security -o "$work/camera-$architecture"
  clang -O2 -Wall -Wextra -std=c11 -arch "$architecture" -mmacosx-version-min=14.0 -bundle \
    "-DRV_SIGNING_TEAM=\"$team\"" "$root/VirtualDevices/Microphone/driver.c" \
    -framework CoreFoundation -framework Security -o "$work/microphone-$architecture"
  clang -O2 -Wall -Wextra -std=c11 -arch "$architecture" -mmacosx-version-min=14.0 -bundle \
    "-DRV_SIGNING_TEAM=\"$team\"" "$root/VirtualDevices/Speaker/driver.c" \
    -framework CoreFoundation -framework Security -o "$work/speaker-$architecture"
  clang -O2 -Wall -Wextra -fobjc-arc -arch "$architecture" -mmacosx-version-min=14.0 \
    "$root/Lifecycle/ReVoyageSpeakerInstaller.m" -framework AppKit -framework Security -o "$work/output-installer-$architecture"
  clang -O2 -Wall -Wextra -fobjc-arc -arch "$architecture" -mmacosx-version-min=14.0 \
    "$root/Lifecycle/ReVoyageDeviceInstaller.m" -framework AppKit -framework Security -o "$work/installer-$architecture"
done
lipo -create "$work/"camera-* -output "$camera/Contents/MacOS/ReVoyageCamera"
lipo -create "$work/"microphone-* -output "$microphone/Contents/MacOS/ReVoyageMicrophone"
lipo -create "$work/"speaker-* -output "$speaker/Contents/MacOS/ReVoyageSpeaker"
lipo -create "$work/"output-installer-* -output "$app/Contents/MacOS/ReVoyageSpeakerInstaller"
lipo -create "$work/"installer-* -output "$app/Contents/MacOS/ReVoyageDeviceInstaller"
/usr/bin/python3 - "$camera" "$microphone" "$team" "$root" "$speaker" <<'PY'
import plistlib,sys
from pathlib import Path
camera,microphone,team,root,speaker=map(Path,sys.argv[1:])
team=sys.argv[3]
common={'CFBundleVersion':'1','CFBundleShortVersionString':'1.0','LSMinimumSystemVersion':'14.0'}
c={**common,'CFBundleIdentifier':'com.targetbridge.sender.camera','CFBundleExecutable':'ReVoyageCamera',
   'CFBundleName':'ReVoyage Camera','CFBundlePackageType':'SYSX','ReVoyageSigningTeam':team,
   'CMIOExtension':{'CMIOExtensionMachServiceName':team+'.com.targetbridge.sender.camera'},
   'NSSystemExtensionUsageDescription':'Use the paired iMac camera as a camera on this Mac.'}
m={**common,'CFBundleIdentifier':'com.targetbridge.sender.microphone','CFBundleExecutable':'ReVoyageMicrophone',
   'CFBundleName':'ReVoyage Microphone','CFBundlePackageType':'BNDL',
   'CFPlugInDynamicRegistration':False,'CFPlugInFactories':{'27BC05E6-4135-4D62-9D58-30D6A17F64F7':'ReVoyageMicrophoneFactory'},
   'CFPlugInTypes':{'443ABAB8-E7B3-491A-B985-BEB9187030DB':['27BC05E6-4135-4D62-9D58-30D6A17F64F7']}}
s={**common,'CFBundleVersion':'3','CFBundleShortVersionString':'1.2',
   'CFBundleIdentifier':'com.targetbridge.sender.speaker','CFBundleExecutable':'ReVoyageSpeaker',
   'CFBundleName':'ReVoyage iMac Speakers','CFBundlePackageType':'BNDL',
   'CFPlugInDynamicRegistration':False,'CFPlugInFactories':{'71086170-0F73-40C4-A7D7-9EA9CE8F0585':'ReVoyageSpeakerFactory'},
   'CFPlugInTypes':{'443ABAB8-E7B3-491A-B985-BEB9187030DB':['71086170-0F73-40C4-A7D7-9EA9CE8F0585']}}
for path,obj in [(camera,c),(microphone,m),(speaker,s)]:
 (path/'Contents/Info.plist').write_bytes(plistlib.dumps(obj))
entitlements=plistlib.loads((root/'VirtualDevices/Camera/Extension.entitlements').read_bytes())
entitlements['com.apple.security.application-groups']=[team+'.com.targetbridge.sender']
(camera/'Contents/Resources').mkdir(exist_ok=True)
(camera/'Contents/Resources/signing-entitlements.plist').write_bytes(plistlib.dumps(entitlements))
PY
# Sign nested products before Xcode signs the containing application. With no
# identity, leave build/test products unsigned; activation is explicitly gated.
if [ "${CODE_SIGNING_ALLOWED:-NO}" = YES ] && [ -n "${EXPANDED_CODE_SIGN_IDENTITY:-}" ]; then
  test -n "$team"
  codesign --force --options runtime --sign "$EXPANDED_CODE_SIGN_IDENTITY" \
    --entitlements "$camera/Contents/Resources/signing-entitlements.plist" "$camera"
  codesign --force --options runtime --sign "$EXPANDED_CODE_SIGN_IDENTITY" "$microphone"
  codesign --force --options runtime --sign "$EXPANDED_CODE_SIGN_IDENTITY" "$speaker"
  codesign --force --options runtime --sign "$EXPANDED_CODE_SIGN_IDENTITY" "$app/Contents/MacOS/ReVoyageSpeakerInstaller"
  codesign --force --options runtime --sign "$EXPANDED_CODE_SIGN_IDENTITY" "$app/Contents/MacOS/ReVoyageDeviceInstaller"
fi
