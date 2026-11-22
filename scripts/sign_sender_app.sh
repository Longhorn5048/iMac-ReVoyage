#!/bin/sh
set -eu
APP="$1"
# REVOYAGE_SIGN_IDENTITY selects the codesign identity. Unset or "-" keeps the
# ad-hoc signature used for local and CI builds. For a distributable build set
#   REVOYAGE_SIGN_IDENTITY="Developer ID Application: NAME (TEAMID)"
#   REVOYAGE_TEAM_ID=TEAMID
#   REVOYAGE_PROVISIONING_PROFILE=/path/to/profile.provisionprofile  (optional)
# and build the app with the same REVOYAGE_TEAM_ID so the virtual devices
# carry that team. See docs/SigningNotarization.md.
IDENTITY="${REVOYAGE_SIGN_IDENTITY:--}"
xattr -cr "$APP"
if [ "$IDENTITY" != "-" ]; then
  TEAM="${REVOYAGE_TEAM_ID:-}"
  case "$TEAM" in ""|*[!A-Z0-9]*) echo "REVOYAGE_TEAM_ID must be the 10-character team ID" >&2; exit 64 ;; esac
  [ "${#TEAM}" -eq 10 ] || { echo "REVOYAGE_TEAM_ID must be the 10-character team ID" >&2; exit 64; }
  BUILT_TEAM="$(/usr/libexec/PlistBuddy -c 'Print :ReVoyageSigningTeam' "$APP/Contents/Info.plist" 2>/dev/null || true)"
  if [ "$BUILT_TEAM" != "$TEAM" ]; then
    echo "App was built for team '${BUILT_TEAM}', not $TEAM. Rebuild with REVOYAGE_TEAM_ID=$TEAM." >&2
    exit 65
  fi
  # Xcode is not signing here, so expand the team prefix it would have filled in.
  APP_ENTITLEMENTS="$(mktemp "${TMPDIR:-/tmp}/revoyage-entitlements.XXXXXX")"
  trap 'rm -f "$APP_ENTITLEMENTS"' EXIT HUP INT TERM
  sed "s/\$(TeamIdentifierPrefix)/$TEAM./g" \
    "$(dirname "$0")/../TargetBridge-Sender/TargetBridgeSupport/Sender.entitlements" > "$APP_ENTITLEMENTS"
  if [ -n "${REVOYAGE_PROVISIONING_PROFILE:-}" ]; then
    cp "$REVOYAGE_PROVISIONING_PROFILE" "$APP/Contents/embedded.provisionprofile"
  fi
  CAMERA="$APP/Contents/Library/SystemExtensions/com.targetbridge.sender.camera.systemextension"
  MAIN="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$APP/Contents/Info.plist")"
  sign() { codesign --force --options runtime --timestamp --sign "$IDENTITY" "$@"; }
  # Inside out. --deep is not used: it skips the HAL drivers in Resources and
  # would replace the camera extension's entitlements.
  for item in "$APP"/Contents/Frameworks/*; do
    [ -e "$item" ] && sign "$item"
  done
  for driver in ReVoyageMicrophone.driver ReVoyageSpeaker.driver; do
    [ -d "$APP/Contents/Resources/$driver" ] && sign "$APP/Contents/Resources/$driver"
  done
  for helper in "$APP"/Contents/MacOS/*; do
    [ "$(basename "$helper")" = "$MAIN" ] || sign "$helper"
  done
  if [ -d "$CAMERA" ]; then
    sign --entitlements "$CAMERA/Contents/Resources/signing-entitlements.plist" "$CAMERA"
  fi
  sign --entitlements "$APP_ENTITLEMENTS" "$APP"
  codesign --verify --deep --strict "$APP"
  exit 0
fi
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
