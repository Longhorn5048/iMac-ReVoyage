#!/bin/sh
set -eu
root="$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)"
work="$(mktemp -d "${TMPDIR:-/tmp}/revoyage-network-tests.XXXXXX")"
trap 'rm -rf "$work"' EXIT HUP INT TERM
clang -O1 -g -Wall -Wextra -fsanitize=address,undefined \
    "$root/scripts/tests/test_wired_network.c" -o "$work/test_network"
"$work/test_network"
