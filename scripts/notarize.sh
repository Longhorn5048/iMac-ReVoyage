#!/bin/sh
# Submit a Developer ID signed archive (.zip, .dmg or .pkg) to Apple's notary
# service and staple the ticket. Nothing here runs during a normal build.
#
#   REVOYAGE_NOTARY_PROFILE  keychain profile created once with
#                            xcrun notarytool store-credentials
#   REVOYAGE_STAPLE          optional path to staple (.app, .dmg or .pkg);
#                            a .zip itself cannot be stapled
#
# See docs/SigningNotarization.md.
set -eu
ARCHIVE="${1:-}"
if [ -z "$ARCHIVE" ] || [ ! -f "$ARCHIVE" ]; then
  echo "usage: REVOYAGE_NOTARY_PROFILE=<profile> $0 <archive.zip|.dmg|.pkg>" >&2
  exit 64
fi
PROFILE="${REVOYAGE_NOTARY_PROFILE:-}"
if [ -z "$PROFILE" ]; then
  echo "REVOYAGE_NOTARY_PROFILE is not set; nothing was submitted." >&2
  exit 64
fi
xcrun notarytool submit "$ARCHIVE" --keychain-profile "$PROFILE" --wait
STAPLE="${REVOYAGE_STAPLE:-}"
if [ -z "$STAPLE" ]; then
  case "$ARCHIVE" in *.dmg|*.pkg) STAPLE="$ARCHIVE" ;; esac
fi
if [ -n "$STAPLE" ]; then
  xcrun stapler staple "$STAPLE"
  xcrun stapler validate "$STAPLE"
fi
