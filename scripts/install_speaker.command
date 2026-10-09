#!/bin/zsh
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
for APP in "$HOME/Applications/iMac ReVoyage Sender.app" \
           "/Applications/iMac ReVoyage Sender.app" \
           "$SCRIPT_DIR/iMac ReVoyage Sender.app"; do
    HELPER="$APP/Contents/MacOS/ReVoyageSpeakerInstaller"
    if [[ -x "$HELPER" && -d "$APP/Contents/Resources/ReVoyageSpeaker.driver" ]]; then
        echo '安装独立的 iMac 扬声器输出设备；macOS 将请求管理员授权。'
        if "$HELPER" --app "$APP"; then
            echo '请重启 Mac mini，然后在系统声音输出中选择 ReVoyage — iMac Speakers。'
            read -r '?按回车退出。' || true
            exit 0
        fi
        echo '扬声器安装未完成，可以稍后在 Sender 设置中重试。'
        read -r '?按回车退出。' || true
        exit 1
    fi
done
echo '未找到包含 iMac 扬声器的新版 Sender，请先运行安装 Sender.command。'
read -r '?按回车退出。' || true
exit 1
