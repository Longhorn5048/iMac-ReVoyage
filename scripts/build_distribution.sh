#!/bin/zsh
# Single current-source distribution entry point for CI, releases and previews.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
NAME="${REVOYAGE_PACKAGE_NAME:-iMac-ReVoyage-Preview}"
[[ "$NAME" == [A-Za-z0-9]* && "$NAME" != *[^A-Za-z0-9._-]* ]] || exit 1
WORK="$(mktemp -d "${TMPDIR:-/tmp}/revoyage-distribution.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
STAGE="$WORK/stage"
mkdir -p "$ROOT/build"
"$ROOT/scripts/build_core_apps.sh"
ditto /tmp/imac-revoyage-deps/core-stage "$STAGE"
WATCHER="$STAGE/Receiver/iMac ReVoyage Storage Watcher.app"
mkdir -p "$WATCHER/Contents/MacOS"
clang -O2 -Wall -Wextra -Wno-unused-parameter -fobjc-arc -arch x86_64 -mmacosx-version-min=10.15 \
  "$ROOT/StorageWatcher/main.m" "$ROOT/TargetBridge-Receiver/TBReceiverC/src/tb_storage_bridge.m" \
  -framework Foundation -o "$WATCHER/Contents/MacOS/StorageWatcher"
cat > "$WATCHER/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>re.voyage.storage-watcher</string>
<key>CFBundleName</key><string>iMac ReVoyage Storage Watcher</string>
<key>CFBundleExecutable</key><string>StorageWatcher</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.6.0</string>
<key>CFBundleVersion</key><string>6</string>
<key>LSMinimumSystemVersion</key><string>10.15</string>
<key>LSBackgroundOnly</key><true/>
</dict></plist>
PLIST
cp "$ROOT/scripts/install_receiver.command" "$ROOT/scripts/uninstall_receiver.command" "$STAGE/Receiver/"
cp "$ROOT/scripts/uninstall_sender.command" "$STAGE/Sender/"
cp "$ROOT/scripts/install_sender.command" "$STAGE/Sender/安装 Sender.command"
cp "$ROOT/scripts/install_speaker.command" "$STAGE/Sender/安装 iMac 扬声器.command"
mkdir -p "$STAGE/docs"
cp "$ROOT/docs/ClarityVolumeFix-2026-10-09.md" "$STAGE/docs/"
cp "$ROOT/docs/AudioThemeFix-2026-10-09.md" "$STAGE/docs/"
cp "$ROOT/docs/QuickStart-ZH.md" "$ROOT/docs/Compatibility.md" "$ROOT/docs/Optimization-2026-10-05.md" "$ROOT/docs/Testing.md" "$ROOT/docs/HardwareAcceptance.md" "$ROOT/docs/SenderSleepSync-2026-10-08.md" "$ROOT/docs/ReceiverDebug-2026-10-08.md" "$ROOT/docs/ReceiverRemoteUpdate-2026-10-08.md" "$ROOT/docs/AudioResume-2026-10-08.md" "$ROOT/docs/ReceiverSSH-2026-10-08.md" "$ROOT/docs/IMacSpeakerDevice-2026-10-09.md" "$STAGE/docs/"
for bundle in "$STAGE/Receiver/"*.app "$STAGE/Sender/"*.app; do
  xattr -cr "$bundle"
  if [[ "$bundle" == "$STAGE/Sender/"* ]]; then
    /bin/sh "$ROOT/scripts/sign_sender_app.sh" "$bundle"
  else
    codesign --force --deep --sign - "$bundle"
  fi
  codesign --verify --deep --strict "$bundle"
  plutil -lint "$bundle/Contents/Info.plist"
done
python3 "$ROOT/scripts/package_manifest.py" "$ROOT" "$STAGE"
(cd "$STAGE"; zip -q -r -X "$WORK/$NAME.zip" Receiver Sender Sources docs BuildManifest.json)
cp "$WORK/$NAME.zip" "$ROOT/build/$NAME.zip"
(cd "$ROOT/build"; shasum -a 256 "$NAME.zip" > "$NAME.zip.sha256")
echo "Distribution: $ROOT/build/$NAME.zip"
