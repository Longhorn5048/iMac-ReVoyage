#!/bin/zsh
set -euo pipefail

SHARE_NAME="ReVoyageStorage"
SHARING_TOOL="${REVOYAGE_SHARING_TOOL:-/usr/sbin/sharing}"
SUDO_TOOL="${REVOYAGE_SUDO_TOOL:-/usr/bin/sudo}"
STORAGE_DIR="${REVOYAGE_STORAGE_DIR:-$HOME/Shared/ReVoyage Storage}"
SUPPORT_DIR="${REVOYAGE_STORAGE_SUPPORT_DIR:-$HOME/Library/Application Support/ReVoyage}"
MARKER="$SUPPORT_DIR/storage-share-path"

if [[ ! -x "$SHARING_TOOL" || ! -x "$SUDO_TOOL" ]]; then
    echo "缺少 macOS sharing 或 sudo 工具，未更改 SMB 配置。" >&2
    exit 1
fi

if [[ -L "$STORAGE_DIR" || -L "$SUPPORT_DIR" ]]; then
    echo "存储目录和 ReVoyage 配置目录不能是符号链接。" >&2
    exit 1
fi
mkdir -p "$STORAGE_DIR" "$SUPPORT_DIR"
if [[ -L "$STORAGE_DIR" || ! -d "$STORAGE_DIR" ]]; then
    echo "存储目录必须是普通目录：$STORAGE_DIR" >&2
    exit 1
fi
if [[ -L "$SUPPORT_DIR" || ! -d "$SUPPORT_DIR" ]]; then
    echo "ReVoyage 配置目录必须是普通目录：$SUPPORT_DIR" >&2
    exit 1
fi
chmod 700 "$STORAGE_DIR" "$SUPPORT_DIR"
STORAGE_PATH="$(cd "$STORAGE_DIR" && pwd -P)"

if [[ -f "$MARKER" ]]; then
    SAVED_PATH="$(< "$MARKER")"
    if [[ "$SAVED_PATH" != "$STORAGE_PATH" ]]; then
        echo "已有 ReVoyage SMB 共享记录指向另一目录；请先检查后再更改。" >&2
        exit 1
    fi
    SHARE_ARGS=(-e "$SHARE_NAME")
else
    SHARE_ARGS=(-a "$STORAGE_PATH")
fi

MARKER_TEMP="$(mktemp "$MARKER.tmp.XXXXXX")"
trap 'rm -f "$MARKER_TEMP"' EXIT HUP INT TERM
(umask 077; print -r -- "$STORAGE_PATH" > "$MARKER_TEMP")

echo "将为当前账户建立 SMB 共享 '$SHARE_NAME'。访客访问关闭，连接需要 macOS 账户认证。"
echo "sudo 会请求管理员确认；ReVoyage 不会保存管理员密码。"
"$SUDO_TOOL" "$SHARING_TOOL" "${SHARE_ARGS[@]}" \
    -S "$SHARE_NAME" -n "$SHARE_NAME" -s 001 -g 000 -R 0

if ! mv -f "$MARKER_TEMP" "$MARKER"; then
    "$SUDO_TOOL" "$SHARING_TOOL" -r "$SHARE_NAME" || true
    echo "无法保存共享记录标记，已尝试回滚 SMB 共享。" >&2
    exit 1
fi
trap - EXIT HUP INT TERM

echo "SMB 已启用。Sender 可连接 smb://$(scutil --get LocalHostName 2>/dev/null || hostname)/$SHARE_NAME"
echo "若系统级 SMB 尚未启用，请在系统偏好设置 > 共享 > 文件共享 > 选项中启用 SMB，并允许当前账户连接。"
echo "共享目录：$STORAGE_PATH"
echo "此目录位于当前用户主目录所在磁盘；数据仍应另有备份。"
