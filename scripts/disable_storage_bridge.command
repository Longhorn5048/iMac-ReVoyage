#!/bin/zsh
set -euo pipefail

SHARE_NAME="ReVoyageStorage"
SHARING_TOOL="${REVOYAGE_SHARING_TOOL:-/usr/sbin/sharing}"
SUDO_TOOL="${REVOYAGE_SUDO_TOOL:-/usr/bin/sudo}"
SUPPORT_DIR="${REVOYAGE_STORAGE_SUPPORT_DIR:-$HOME/Library/Application Support/ReVoyage}"
MARKER="$SUPPORT_DIR/storage-share-path"

if [[ -L "$SUPPORT_DIR" ]]; then
    echo "ReVoyage 配置目录不能是符号链接；未更改 SMB 配置。" >&2
    exit 1
fi
if [[ ! -f "$MARKER" ]]; then
    echo "未找到 ReVoyage 管理的 SMB 共享记录；未更改文件或其它共享。"
    exit 0
fi
if [[ -L "$MARKER" ]]; then
    echo "共享记录不能是符号链接；未更改 SMB 配置。" >&2
    exit 1
fi
if [[ ! -x "$SHARING_TOOL" || ! -x "$SUDO_TOOL" ]]; then
    echo "缺少 macOS sharing 或 sudo 工具，未更改 SMB 配置。" >&2
    exit 1
fi

SAVED_PATH="$(< "$MARKER")"
if [[ -z "$SAVED_PATH" ]]; then
    echo "共享记录标记无效；请检查后再移除。" >&2
    exit 1
fi

echo "将关闭 ReVoyage SMB 共享；共享目录和其中的数据会保留。"
"$SUDO_TOOL" "$SHARING_TOOL" -r "$SHARE_NAME"
rm -f "$MARKER"
echo "SMB 共享已关闭；数据目录保留在：$SAVED_PATH"
