#!/bin/sh
# Source-only regression: synthetic loopback, generated images and temporary
# installation trees. Never activates an extension, installs a HAL driver,
# captures physical devices or uninstalls the user's application.
set -eu
root="$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)"
work="$(mktemp -d "${TMPDIR:-/tmp}/revoyage-media-check.XXXXXX")"
trap 'rm -rf "$work"' EXIT HUP INT TERM
clang -O1 -g -Wall -Wextra -fobjc-arc -fsanitize=address,undefined -mmacosx-version-min=10.15 \
  "$root/MediaBridge/main.m" -framework AppKit -framework AVFoundation -framework CoreImage \
  -framework CoreMedia -framework CoreVideo -framework ImageIO -o "$work/service"
clang -O1 -g -Wall -Wextra -fobjc-arc -fsanitize=address,undefined -mmacosx-version-min=10.15 \
  "$root/MediaBridge/tests/test_queue.m" -framework AppKit -framework AVFoundation -framework CoreImage \
  -framework CoreMedia -framework CoreVideo -framework ImageIO -o "$work/queue"
clang -O1 -g -Wall -Wextra -fobjc-arc -fsanitize=address,undefined -mmacosx-version-min=14.0 \
  "$root/VirtualDevices/Camera/test_output.m" -framework Foundation -framework CoreGraphics \
  -framework CoreMediaIO -framework CoreAudio -framework CoreMedia -framework CoreVideo -framework ImageIO -o "$work/camera"
clang -O1 -g -Wall -Wextra -std=c11 -fsanitize=address,undefined -mmacosx-version-min=14.0 \
  "$root/VirtualDevices/Microphone/test_driver.c" -framework CoreFoundation -framework Security -o "$work/microphone"
clang -O1 -g -Wall -Wextra -fobjc-arc -mmacosx-version-min=10.15 \
  "$root/Lifecycle/ReVoyageUninstaller.m" -framework AppKit -framework Security -o "$work/uninstaller"
"$work/queue"
"$work/camera"
"$work/microphone"
python3 "$root/MediaBridge/tests/test_service.py" "$work/service"
python3 "$root/Lifecycle/tests/test_uninstaller.py" "$work/uninstaller"
python3 "$root/Lifecycle/tests/test_receiver_install.py"
