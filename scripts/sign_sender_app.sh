#!/bin/sh
set -eu
APP="$1"
xattr -cr "$APP"
# HAL bundles stored in Resources are not traversed by codesign --deep.
SPEAKER="$APP/Contents/Resources/ReVoyageSpeaker.driver"
if [ -d "$SPEAKER" ]; then
  codesign --force --sign - "$SPEAKER"
fi
codesign --force --deep --sign - "$APP"
# Local development builds need a stable identity across recompiles so a
# user's macOS privacy choice is not tied to one executable's cdhash.
# Sign only the outer bundle with this requirement; helpers keep their IDs.
codesign --force --sign - --identifier com.targetbridge.sender \
  --requirements '=designated => identifier "com.targetbridge.sender"' "$APP"
codesign --verify --deep --strict "$APP"
