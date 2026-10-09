#!/bin/sh
set -eu

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)"
TEMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/revoyage-storage-test.XXXXXX")"
trap 'rm -rf "$TEMP_DIR"' EXIT HUP INT TERM

MOCK_SUDO="$TEMP_DIR/sudo"
MOCK_SHARING="$TEMP_DIR/sharing"
MOCK_LOG="$TEMP_DIR/commands.log"
STORAGE_DIR="$TEMP_DIR/disk with spaces/ReVoyage Storage"
SUPPORT_DIR="$TEMP_DIR/support"
mkdir -p "$TEMP_DIR/disk with spaces"

cat > "$MOCK_SUDO" <<'MOCK'
#!/bin/sh
set -eu
printf 'sudo' >> "$REVOYAGE_STORAGE_TEST_LOG"
for arg do printf '\t%s' "$arg" >> "$REVOYAGE_STORAGE_TEST_LOG"; done
printf '\n' >> "$REVOYAGE_STORAGE_TEST_LOG"
"$@"
MOCK

cat > "$MOCK_SHARING" <<'MOCK'
#!/bin/sh
set -eu
if [ "${REVOYAGE_STORAGE_MOCK_FAIL:-0}" = 1 ]; then exit 19; fi
printf 'sharing' >> "$REVOYAGE_STORAGE_TEST_LOG"
for arg do printf '\t%s' "$arg" >> "$REVOYAGE_STORAGE_TEST_LOG"; done
printf '\n' >> "$REVOYAGE_STORAGE_TEST_LOG"
MOCK

chmod +x "$MOCK_SUDO" "$MOCK_SHARING"
export REVOYAGE_SUDO_TOOL="$MOCK_SUDO"
export REVOYAGE_SHARING_TOOL="$MOCK_SHARING"
export REVOYAGE_STORAGE_DIR="$STORAGE_DIR"
export REVOYAGE_STORAGE_SUPPORT_DIR="$SUPPORT_DIR"
export REVOYAGE_STORAGE_TEST_LOG="$MOCK_LOG"

"$ROOT/scripts/enable_storage_bridge.command" >/dev/null
test -d "$STORAGE_DIR"
test "$(stat -f '%Lp' "$STORAGE_DIR")" = 700
test "$(cat "$SUPPORT_DIR/storage-share-path")" = "$(cd "$STORAGE_DIR" && pwd -P)"
grep -F "sharing	-a	$(cd "$STORAGE_DIR" && pwd -P)	-S	ReVoyageStorage	-n	ReVoyageStorage	-s	001	-g	000	-R	0" "$MOCK_LOG" >/dev/null

"$ROOT/scripts/enable_storage_bridge.command" >/dev/null
grep -F "sharing	-e	ReVoyageStorage	-S	ReVoyageStorage	-n	ReVoyageStorage	-s	001	-g	000	-R	0" "$MOCK_LOG" >/dev/null

"$ROOT/scripts/disable_storage_bridge.command" >/dev/null
test ! -e "$SUPPORT_DIR/storage-share-path"
test -d "$STORAGE_DIR"
grep -F "sharing	-r	ReVoyageStorage" "$MOCK_LOG" >/dev/null

if REVOYAGE_STORAGE_MOCK_FAIL=1 "$ROOT/scripts/enable_storage_bridge.command" >/dev/null 2>&1; then
    echo "expected sharing failure to propagate" >&2
    exit 1
fi
test ! -e "$SUPPORT_DIR/storage-share-path"

ORIGINAL_SUPPORT_DIR="$TEMP_DIR/support-original"
EXTERNAL_SUPPORT_DIR="$TEMP_DIR/external-support"
mv "$SUPPORT_DIR" "$ORIGINAL_SUPPORT_DIR"
mkdir -m 755 "$EXTERNAL_SUPPORT_DIR"
ln -s "$EXTERNAL_SUPPORT_DIR" "$SUPPORT_DIR"
if "$ROOT/scripts/enable_storage_bridge.command" >/dev/null 2>&1; then
    echo "expected symlinked support directory to be rejected" >&2
    exit 1
fi
test "$(stat -f '%Lp' "$EXTERNAL_SUPPORT_DIR")" = 755

BROKEN_STORAGE_TARGET="$TEMP_DIR/must-not-be-created"
BROKEN_STORAGE_DIR="$TEMP_DIR/broken-storage-link"
ln -s "$BROKEN_STORAGE_TARGET" "$BROKEN_STORAGE_DIR"
if REVOYAGE_STORAGE_DIR="$BROKEN_STORAGE_DIR" "$ROOT/scripts/enable_storage_bridge.command" >/dev/null 2>&1; then
    echo "expected symlinked storage directory to be rejected" >&2
    exit 1
fi
test ! -e "$BROKEN_STORAGE_TARGET"

echo "storage share script tests: 6 scenarios passed"
