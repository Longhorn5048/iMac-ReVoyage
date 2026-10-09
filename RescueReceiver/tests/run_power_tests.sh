#!/bin/sh
set -eu
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
BIN="${TMPDIR:-/tmp}/revoyage-power-controller-tests-$$"
trap 'rm -f "$BIN"' EXIT HUP INT TERM
${CC:-clang} -O1 -g -fobjc-arc -Wall -Wextra \
  "$ROOT/tests/test_power_controller.m" "$ROOT/DisplaySignalState.c" \
  -framework AppKit -framework AVFoundation -framework IOKit -o "$BIN"
"$BIN"
