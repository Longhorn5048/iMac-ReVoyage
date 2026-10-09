#!/bin/zsh
set -euo pipefail

PACKAGE_DIR="$(cd "$(dirname "$0")" && pwd)"
MODE=(--gui)
case "${1:-}" in
    --dry-run) MODE=() ;;
    --apply) MODE=(--apply) ;;
    "") ;;
    *) echo "Usage: $0 [--dry-run|--apply]" >&2; exit 64 ;;
esac
for APP in "$HOME/Applications/iMac ReVoyage/iMac ReVoyage Receiver.app" \
           "$PACKAGE_DIR/iMac ReVoyage Receiver.app" \
           "$PACKAGE_DIR/../build/TargetBridge Receiver.app"; do
    HELPER="$APP/Contents/MacOS/ReVoyageUninstaller"
    if [[ -x "$HELPER" ]]; then
        exec "$HELPER" --role receiver --app "$APP" "${MODE[@]}"
    fi
done
echo "未找到完整卸载器。请使用含 ReVoyageUninstaller 的新版 Receiver 安装包。" >&2
exit 1
