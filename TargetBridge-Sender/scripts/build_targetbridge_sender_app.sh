#!/bin/zsh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
REPO_ROOT="$(cd "$ROOT/.." && pwd)"
DERIVED_DATA_DIR="${ROOT}/.build/DerivedData"
BUILD_DIR="${DERIVED_DATA_DIR}/Build/Products/Debug"
SOURCE_APP="${BUILD_DIR}/TargetBridge.app"
DEST_DIR="${REPO_ROOT}/build"
DEST_APP="${DEST_DIR}/TargetBridge.app"

cd "$ROOT"

xcodegen generate

xcodebuild \
  -project "$ROOT/TargetBridge.xcodeproj" \
  -scheme TBDisplaySender \
  -configuration Debug \
  -derivedDataPath "$DERIVED_DATA_DIR" \
  ARCHS=arm64 \
  CODE_SIGN_IDENTITY="" \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGNING_ALLOWED=NO \
  build

mkdir -p "$DEST_DIR"
SIGN_STAGE="$(mktemp -d "${TMPDIR:-/tmp}/revoyage-sender-sign.XXXXXX")"
trap 'rm -rf "$SIGN_STAGE"' EXIT
ditto "$SOURCE_APP" "$SIGN_STAGE/TargetBridge.app"
echo "Signing sender application..."
/bin/sh "$REPO_ROOT/scripts/sign_sender_app.sh" "$SIGN_STAGE/TargetBridge.app"
rm -rf "$DEST_APP"
ditto "$SIGN_STAGE/TargetBridge.app" "$DEST_APP"
xattr -cr "$DEST_APP" || true
codesign --verify --deep --strict "$DEST_APP"
touch "$DEST_APP"

echo "TargetBridge sender built: $DEST_APP"
echo "Local DerivedData: $DERIVED_DATA_DIR"
