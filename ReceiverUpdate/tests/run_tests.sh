#!/bin/sh
# Synthetic loopback and temporary installation trees only. No real services.
set -eu
root="$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)"
work="$(mktemp -d "${TMPDIR:-/tmp}/revoyage-updater-check.XXXXXX")"
trap 'rm -rf "$work"' EXIT HUP INT TERM
mkdir -p "$work/app/Contents/MacOS" "$work/app/Contents/Resources"
cp "$root/scripts/install_receiver.command" "$work/app/Contents/Resources/"
clang -O1 -g -Wall -Wextra -Werror=unguarded-availability-new -fobjc-arc \
  -fsanitize=address,undefined -mmacosx-version-min=10.15 -DRV_UPDATER_TESTING \
  "$root/ReceiverUpdate/main.m" "$root/TargetBridge-Sender/TBDisplayShared/TBWiredNetwork.m" \
  -framework Foundation -framework SystemConfiguration -o "$work/app/Contents/MacOS/updater"
python3 "$root/ReceiverUpdate/tests/test_updater.py" "$work/app/Contents/MacOS/updater"
