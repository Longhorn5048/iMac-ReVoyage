#!/bin/zsh
# Install a single current Sender and explicitly launch that path.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SOURCE="${1:-$SCRIPT_DIR/iMac ReVoyage Sender.app}"
APPLICATIONS_DIR="${REVOYAGE_SENDER_APPLICATIONS_DIR:-$HOME/Applications}"
DEST="$APPLICATIONS_DIR/iMac ReVoyage Sender.app"
STAGE="$APPLICATIONS_DIR/.ReVoyage-Sender-install-$$.app"
BACKUP="$APPLICATIONS_DIR/.ReVoyage-Sender-previous.app.backup"

fail() { echo "$1"; read -r '?按回车退出。' || true; exit 1; }
[[ -f "$SOURCE/Contents/Info.plist" ]] || fail '找不到安装包中的 Sender。请先完整解压，再运行安装入口。'
IDENTIFIER=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$SOURCE/Contents/Info.plist")
[[ "$IDENTIFIER" == com.targetbridge.sender ]] || fail '此应用不是 Sender。'
VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$SOURCE/Contents/Info.plist")
codesign --verify --deep --strict "$SOURCE" || fail '应用签名校验失败，请重新解压安装包。'

echo "安装 Sender $VERSION；正在关闭旧 Sender…"
for pid in $(pgrep -x TargetBridge 2>/dev/null || true); do
    BIN=$(ps -p "$pid" -o comm= 2>/dev/null || true)
    RUNNING_APP="${BIN%/Contents/MacOS/*}"
    [[ -f "$RUNNING_APP/Contents/Info.plist" ]] || continue
    RUNNING_ID=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$RUNNING_APP/Contents/Info.plist" 2>/dev/null || true)
    [[ "$RUNNING_ID" == com.targetbridge.sender ]] || continue
    kill -TERM "$pid" 2>/dev/null || true
    for attempt in {1..25}; do
        kill -0 "$pid" 2>/dev/null || break
        sleep 0.2
    done
    if kill -0 "$pid" 2>/dev/null; then fail '旧 Sender 尚未退出，请在旧窗口按 Command+Q 后再运行安装入口。'; fi
done

mkdir -p "$APPLICATIONS_DIR"
trap 'if [[ -d "$STAGE" ]]; then rm -rf "$STAGE"; fi' EXIT
ditto "$SOURCE" "$STAGE"
xattr -cr "$STAGE"
codesign --verify --deep --strict "$STAGE" || fail '安装副本校验失败，旧应用未替换。'
if [[ -e "$DEST" ]]; then
    [[ ! -e "$BACKUP" ]] || rm -rf "$BACKUP"
    mv "$DEST" "$BACKUP"
fi
if ! mv "$STAGE" "$DEST"; then
    if [[ -e "$BACKUP" && ! -e "$DEST" ]]; then mv "$BACKUP" "$DEST"; fi
    fail '安装失败，已恢复旧应用。'
fi
echo "已安装 Sender $VERSION：$DEST"
echo '现在启动此安装副本；无需配对码。若 macOS 提示录屏授权，请允许这个新版。'
open -n "$DEST"
