#!/bin/sh
set -eu
root="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
app="$1"
architectures="$2"
minimum="$3"
mkdir -p "$app/Contents/MacOS"
work="$(mktemp -d "${TMPDIR:-/tmp}/revoyage-uninstaller-build.XXXXXX")"
trap 'rm -rf "$work"' EXIT HUP INT TERM
for architecture in $architectures; do
  case "$architecture" in arm64|x86_64) ;; *) exit 64 ;; esac
  clang -O2 -Wall -Wextra -fobjc-arc -arch "$architecture" -mmacosx-version-min="$minimum" \
    "$root/Lifecycle/ReVoyageUninstaller.m" \
    -framework Foundation -framework AppKit -framework Security \
    -o "$work/$architecture"
done
lipo -create "$work/"* -output "$app/Contents/MacOS/ReVoyageUninstaller"
