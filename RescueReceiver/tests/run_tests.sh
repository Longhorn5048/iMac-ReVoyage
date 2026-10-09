#!/bin/sh
set -eu
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
BIN="${TMPDIR:-/tmp}/revoyage-display-signal-tests-$$"
trap 'rm -f "$BIN"' EXIT HUP INT TERM
${CC:-cc} -std=c11 -Wall -Wextra -Werror \
  "$ROOT/DisplaySignalState.c" "$ROOT/tests/test_display_signal_state.c" \
  -o "$BIN"
"$BIN"
