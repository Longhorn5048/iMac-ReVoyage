#!/bin/sh
set -eu
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
BIN="${TMPDIR:-/tmp}/revoyage-capture-device-tests-$$"
trap 'rm -f "$BIN"' EXIT HUP INT TERM
${CC:-clang} -fobjc-arc -Wall -Wextra -Werror \
  "$ROOT/tests/test_capture_device_selection.m" -framework Foundation -o "$BIN"
"$BIN"
