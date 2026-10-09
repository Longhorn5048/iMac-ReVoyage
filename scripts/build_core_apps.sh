#!/bin/zsh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$ROOT/build/deps-src"
WORK="/tmp/imac-revoyage-deps"
OUT="$WORK/core-stage"
PREFIX="$WORK/prefix"
FFMPEG_SHA=f0bf043299db9e3caacb435a712fc541fbb07df613c4b893e8b77e67baf3adbe
SDL_SHA=5f5993c530f084535c65a6879e9b26ad441169b3e25d789d83287040a9ca5165
PKGCONF="${PKGCONF:-$(command -v pkgconf || command -v pkg-config || printf '%s/bin/pkgconf' "$(brew --prefix pkgconf)")}"

for tool in cmake nasm xcrun xcodegen otool codesign; do
    command -v "$tool" >/dev/null || { echo "Missing build tool: $tool" >&2; exit 1; }
done
test -x "$PKGCONF" || { echo "Missing pkgconf: $PKGCONF" >&2; exit 1; }
rm -rf "$OUT"
mkdir -p "$SRC" "$WORK" "$OUT/Receiver" "$OUT/Sender" "$OUT/Sources"

fetch() {
    local url="$1" archive_path="$2" hash="$3"
    if [[ ! -s "$archive_path" ]]; then curl -fL --retry 3 -o "$archive_path" "$url"; fi
    local actual="$(openssl dgst -sha256 -r "$archive_path" | awk '{print $1}')"
    [[ "$actual" == "$hash" ]] || { echo "Checksum mismatch: $archive_path" >&2; exit 1; }
}

fetch 'https://www.ffmpeg.org/releases/ffmpeg-7.1.3.tar.xz' \
      "$SRC/ffmpeg-7.1.3.tar.xz" "$FFMPEG_SHA"
fetch 'https://github.com/libsdl-org/SDL/releases/download/release-2.32.10/SDL2-2.32.10.tar.gz' \
      "$SRC/SDL2-2.32.10.tar.gz" "$SDL_SHA"

if [[ ! -f "$WORK/ffmpeg-7.1.3/configure" ]]; then tar -xf "$SRC/ffmpeg-7.1.3.tar.xz" -C "$WORK"; fi
if [[ ! -f "$WORK/SDL2-2.32.10/CMakeLists.txt" ]]; then tar -xf "$SRC/SDL2-2.32.10.tar.gz" -C "$WORK"; fi

if [[ ! -f "$PREFIX/lib/libSDL2-2.0.0.dylib" || ! -f "$PREFIX/lib/pkgconfig/sdl2.pc" || ! -f "$PREFIX/include/SDL2/SDL.h" ]]; then
    cmake -S "$WORK/SDL2-2.32.10" -B "$WORK/sdl2-build" \
      -DCMAKE_BUILD_TYPE=Release -DCMAKE_OSX_ARCHITECTURES=x86_64 \
      -DCMAKE_OSX_DEPLOYMENT_TARGET=10.15 -DCMAKE_INSTALL_PREFIX="$PREFIX" \
      -DSDL_SHARED=ON -DSDL_STATIC=OFF -DSDL_TEST=OFF > "$ROOT/build/sdl2-configure.log" 2>&1
    cmake --build "$WORK/sdl2-build" --parallel 8 > "$ROOT/build/sdl2-build.log" 2>&1
    cmake --install "$WORK/sdl2-build" > "$ROOT/build/sdl2-install.log" 2>&1
fi

if [[ ! -f "$PREFIX/lib/libavcodec.61.dylib" || ! -f "$PREFIX/lib/pkgconfig/libavcodec.pc" || ! -f "$PREFIX/include/libavcodec/avcodec.h" ]]; then
    (
      cd "$WORK/ffmpeg-7.1.3"
      ./configure --prefix="$PREFIX" --arch=x86_64 --target-os=darwin \
        --enable-cross-compile --cc=clang \
        --extra-cflags='-arch x86_64 -mmacosx-version-min=10.15' \
        --extra-ldflags='-arch x86_64 -mmacosx-version-min=10.15' \
        --install-name-dir=@rpath --enable-shared --disable-static \
        --disable-programs --disable-doc --disable-everything \
        --enable-decoder=h264,hevc \
        --enable-hwaccel=h264_videotoolbox,hevc_videotoolbox \
        --enable-videotoolbox --enable-pthreads > "$ROOT/build/ffmpeg-configure.log" 2>&1
      make -j8 > "$ROOT/build/ffmpeg-build.log" 2>&1
      make install > "$ROOT/build/ffmpeg-install.log" 2>&1
    )
fi

(
  cd "$ROOT/TargetBridge-Receiver/TBReceiverC"
  make clean
  PKG_CONFIG_PATH="$PREFIX/lib/pkgconfig" \
  LDFLAGS='-Wl,-rpath,@executable_path/../Frameworks' \
    make -j8 CC='clang -arch x86_64 -mmacosx-version-min=10.15' \
    PKG="$PKGCONF" MACOSX_DEPLOYMENT_TARGET=10.15 \
        APP_VERSION=0.6.2 APP_BUILD=direct-connection > "$ROOT/build/receiver-build.log" 2>&1
)

APP="$OUT/Receiver/iMac ReVoyage Receiver.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Frameworks" "$APP/Contents/Resources/Languages"
cp "$ROOT/TargetBridge-Receiver/TBReceiverC/tbreceiver" "$APP/Contents/MacOS/TargetBridgeReceiver"
cp -L "$PREFIX/lib/libSDL2-2.0.0.dylib" "$APP/Contents/Frameworks/"
cp -L "$PREFIX/lib/libavcodec.61.dylib" "$APP/Contents/Frameworks/"
cp -L "$PREFIX/lib/libavutil.59.dylib" "$APP/Contents/Frameworks/"
cp "$ROOT/TargetBridge-Shared/Languages/"*.json "$APP/Contents/Resources/Languages/"
cp "$ROOT/scripts/install_receiver.command" "$APP/Contents/Resources/install_receiver.command"
xcrun clang -arch x86_64 -mmacosx-version-min=10.15 -fobjc-arc -O2 -Wall -Wextra -Wno-unused-parameter \
  -Werror=unguarded-availability-new "$ROOT/ReceiverUpdate/main.m" \
  "$ROOT/TargetBridge-Sender/TBDisplayShared/TBWiredNetwork.m" \
  -framework Foundation -framework SystemConfiguration -o "$APP/Contents/MacOS/ReVoyageReceiverUpdater"
RECEIVER_BUILD="$(date +%Y%m%d%H%M%S)"
"$ROOT/scripts/build_uninstaller.sh" "$APP" x86_64 10.15
"$ROOT/MediaBridge/build.sh" "$OUT/Receiver/iMac ReVoyage Media Bridge.app"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>re.voyage.receiver</string>
<key>CFBundleName</key><string>iMac ReVoyage Receiver</string>
<key>CFBundleExecutable</key><string>TargetBridgeReceiver</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.6.2</string>
<key>CFBundleVersion</key><string>20261007</string>
<key>LSMinimumSystemVersion</key><string>10.15</string>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $RECEIVER_BUILD" "$APP/Contents/Info.plist"

for dylib in "$APP/Contents/Frameworks/"*.dylib; do
    xattr -cr "$dylib"
    codesign --force --sign - "$dylib"
done
xattr -cr "$APP"
codesign --force --sign - "$APP/Contents/MacOS/ReVoyageUninstaller"
codesign --force --sign - "$APP/Contents/MacOS/ReVoyageReceiverUpdater"
codesign --force --sign - "$APP"

RESCUE_APP_DIR="$OUT/Receiver/iMac ReVoyage Rescue.app" \
  "$ROOT/RescueReceiver/build.sh" >/dev/null
BUILD_INFO="$ROOT/TargetBridge-Sender/TBDisplaySender/TBDisplaySenderBuildInfo.swift"
BUILD_INFO_BACKUP="$WORK/TBDisplaySenderBuildInfo.backup.swift"
cp "$BUILD_INFO" "$BUILD_INFO_BACKUP"
restore_build_info() { cp "$BUILD_INFO_BACKUP" "$BUILD_INFO"; }
trap restore_build_info EXIT
"$ROOT/TargetBridge-Sender/scripts/build_targetbridge_sender_app.sh" > "$ROOT/build/sender-build.log" 2>&1
ditto "$ROOT/build/TargetBridge.app" "$OUT/Sender/iMac ReVoyage Sender.app"
cp "$ROOT/scripts/install_sender.command" "$OUT/Sender/安装 Sender.command"
cp "$ROOT/scripts/uninstall_sender.command" "$OUT/Sender/Uninstall Sender.command"
cp "$ROOT/scripts/uninstall_receiver.command" "$OUT/Receiver/Uninstall Receiver.command"
restore_build_info
trap - EXIT

cp "$ROOT/LICENSE" "$OUT/Receiver/TargetBridge-MIT-LICENSE.txt"
cp "$WORK/ffmpeg-7.1.3/COPYING.LGPLv2.1" "$OUT/Receiver/FFmpeg-LGPL-2.1.txt"
cp "$WORK/SDL2-2.32.10/LICENSE.txt" "$OUT/Receiver/SDL2-zlib-LICENSE.txt"
cp "$SRC/ffmpeg-7.1.3.tar.xz" "$OUT/Sources/"
cp "$SRC/SDL2-2.32.10.tar.gz" "$OUT/Sources/"

echo "Prepared current core applications and pinned dependency sources."
