#!/bin/zsh
# No physical devices or system installation: unit tests and synthetic services.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
TargetBridge-Shared/scripts/check_localizations.sh
python3 scripts/tests/test_package_manifest.py
RescueReceiver/tests/run_tests.sh
RescueReceiver/tests/run_device_tests.sh
RescueReceiver/tests/run_power_tests.sh
scripts/tests/test_media_bridge.sh
ReceiverUpdate/tests/run_tests.sh
PREFIX=/tmp/imac-revoyage-deps/prefix
PKGCONF="${PKGCONF:-$(command -v pkgconf || command -v pkg-config || printf '%s/bin/pkgconf' "$(brew --prefix pkgconf)")}"
PKG_CONFIG_PATH="$PREFIX/lib/pkgconfig" LDFLAGS="-Wl,-rpath,$PREFIX/lib" \
  make -C TargetBridge-Receiver/TBReceiverC all test test-decoder test-session-gate test-display-profile \
  CC='clang -arch x86_64 -mmacosx-version-min=10.15' PKG="$PKGCONF" MACOSX_DEPLOYMENT_TARGET=10.15
INFO=TargetBridge-Sender/TBDisplaySender/TBDisplaySenderBuildInfo.swift
BACKUP="$(mktemp "${TMPDIR:-/tmp}/revoyage-buildinfo.XXXXXX")"
cp "$INFO" "$BACKUP"
trap 'cp "$BACKUP" "$INFO"; rm -f "$BACKUP"' EXIT
xcodebuild test -project TargetBridge-Sender/TargetBridge.xcodeproj -scheme TBDisplaySender \
  -destination 'platform=macOS' -derivedDataPath TargetBridge-Sender/.build/DerivedData \
  CODE_SIGN_IDENTITY='' CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO

scripts/tests/test_speaker_device.sh
/bin/sh scripts/tests/test_wired_network.sh
python3 Lifecycle/tests/test_speaker_installer.py TargetBridge-Sender/.build/DerivedData/Build/Products/Debug/TargetBridge.app
