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
for APP in "$HOME/Applications/iMac ReVoyage Sender.app" \
           "$HOME/Applications/iMac ReVoyage/iMac ReVoyage Sender.app" \
           "/Applications/iMac ReVoyage Sender.app" \
           "/Applications/TargetBridge.app" \
           "$PACKAGE_DIR/iMac ReVoyage Sender.app" \
           "$PACKAGE_DIR/../build/TargetBridge.app"; do
    HELPER="$APP/Contents/MacOS/ReVoyageUninstaller"
    if [[ -x "$HELPER" ]]; then
        if [[ "${1:-}" == "" ]]; then
            exec /usr/bin/open -a "$APP" 'targetbridge://uninstall'
        fi
        exec "$HELPER" --role sender --app "$APP" "${MODE[@]}"
    fi
done
echo "未找到完整卸载器。请使用含 ReVoyageUninstaller 的新版 Sender 安装包。" >&2
exit 1
