#!/bin/sh
# Synthetic host and signature checks only; does not install or register HAL.
set -eu
root="$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)"
work="$(mktemp -d "${TMPDIR:-/tmp}/revoyage-speaker-tests.XXXXXX")"
trap 'rm -rf "$work"' EXIT HUP INT TERM
clang -O1 -g -Wall -Wextra -std=c11 -fsanitize=address,undefined -fno-omit-frame-pointer \
    "$root/VirtualDevices/Speaker/test_driver.c" -framework CoreFoundation -framework Security -o "$work/test_speaker"
codesign --force --sign - --identifier com.targetbridge.sender "$work/test_speaker"
"$work/test_speaker"
