#!/bin/zsh
set -euo pipefail

PACKAGE_DIR="$(cd "$(dirname "$0")" && pwd)"
INSTALL_HOME="$HOME"
REMOTE_UPDATE=0
SSH_ONLY=0
# Filesystem-only fixtures cannot control actual services. No Python dependency.
if [[ "${1:-}" == "--test-root" ]]; then
    [[ "$#" -eq 2 && "${REVOYAGE_DRY_RUN:-0}" == 1 && -d "$2" && ! -L "$2" ]] || exit 64
    INSTALL_HOME="$(cd "$2" && pwd -P)"
    TEST_BASE="$(cd "${TMPDIR:-/tmp}" && pwd -P)"
    [[ "$2" == "$INSTALL_HOME" && "$INSTALL_HOME" == "$TEST_BASE"/revoyage-install-test-*/home ]] || exit 64
elif [[ "$#" -eq 1 && "$1" == --remote-update && "${REVOYAGE_DRY_RUN:-0}" != 1 ]]; then
    REMOTE_UPDATE=1
elif [[ "$#" -eq 1 && "$1" == --enable-ssh ]]; then
    SSH_ONLY=1
elif [[ "$#" -ne 0 ]]; then
    exit 64
fi

ssh_is_enabled() {
    # A loaded job alone is insufficient: it may have been explicitly disabled.
    /bin/launchctl print-disabled system 2>/dev/null | /usr/bin/awk '
        $1 == "\"com.openssh.sshd\"" && $2 == "=>" && $3 == "enabled" { found=1 }
        END { exit !found }' || return 1
    /bin/launchctl print system/com.openssh.sshd >/dev/null 2>&1
}

enable_receiver_ssh() {
    # Even instrumented filesystem fixtures must never request administrator
    # authorization or change a system service. Remote upgrades stay unattended.
    if [[ "${REVOYAGE_DRY_RUN:-0}" == 1 || "$REMOTE_UPDATE" == 1 ]]; then
        return 0
    fi
    if ! ssh_is_enabled; then
        echo "正在开启 macOS 远程登录（SSH）；请在系统授权窗口输入管理员密码。"
        local authorization_ok=0 attempt
        if /usr/bin/osascript -e 'do shell script "/usr/sbin/systemsetup -setremotelogin on" with administrator privileges'; then
            authorization_ok=1
        fi
        # systemsetup may report a permissions error with a successful exit code.
        # Confirm launchd's effective state instead of trusting its output.
        for attempt in 1 2 3 4 5; do
            if ssh_is_enabled; then break; fi
            /bin/sleep 0.2
        done
        if ! ssh_is_enabled; then
            echo "SSH 尚未开启；显示和 Receiver 远程更新服务独立运行。" >&2
            if [[ "$authorization_ok" == 0 ]]; then
                echo "管理员授权未完成或系统命令失败；可稍后重新尝试。" >&2
            fi
            echo "Catalina 及更新系统可能要求终端拥有完整磁盘访问权限：系统偏好设置 → 安全性与隐私 → 隐私 → 完整磁盘访问权限，允许终端并重新打开终端。" >&2
            echo "随后重新运行本安装器并加 --enable-ssh；也可在系统偏好设置 → 共享 → 远程登录中开启。新系统位于系统设置 → 通用 → 共享。" >&2
            /usr/bin/open 'x-apple.systempreferences:com.apple.preferences.sharing?Services_RemoteLogin' >/dev/null 2>&1 || true
            return 1
        fi
    fi
    local receiver_user receiver_host
    receiver_user="$(/usr/bin/id -un)"
    receiver_host="$(/usr/sbin/scutil --get LocalHostName 2>/dev/null)" || receiver_host=""
    echo "SSH 已开启。Sender 的 Receiver 高级服务可使用此 iMac 的账户：$receiver_user"
    [[ -z "$receiver_host" ]] || echo "连接命令：ssh $receiver_user@$receiver_host.local（也可使用 iMac 的有线 IP 地址）"
    echo "SSH 使用此 iMac 的账户密码；若远程登录仅允许指定用户，请确认已允许 $receiver_user。"
}

if [[ "$SSH_ONLY" == 1 ]]; then
    enable_receiver_ssh
    exit $?
fi
TARGET_DIR="$INSTALL_HOME/Applications/iMac ReVoyage"
AGENTS="$INSTALL_HOME/Library/LaunchAgents"
LOGS="$INSTALL_HOME/Library/Logs/iMac ReVoyage"
UID_NUMBER="$(id -u)"
for app in Receiver Rescue 'Storage Watcher'; do
    [[ -d "$PACKAGE_DIR/iMac ReVoyage $app.app" ]] || { echo "缺少 $app.app" >&2; exit 1; }
done
mkdir -p "$TARGET_DIR" "$AGENTS" "$LOGS"
STAGE="$(mktemp -d "$TARGET_DIR/.install.XXXXXX")"
mkdir -p "$STAGE/apps" "$STAGE/agents" "$STAGE/backup-apps" "$STAGE/backup-agents"
typeset -a tx_apps tx_labels tx_running tx_stopped tx_new_apps tx_new_agents
tx_active=0

rollback() {
    [[ "$tx_active" == 1 ]] || return 0
    if [[ "${REVOYAGE_DRY_RUN:-0}" != 1 ]]; then
        for label in "${tx_stopped[@]}"; do
            launchctl bootout "gui/$UID_NUMBER/$label" >/dev/null 2>&1 || true
        done
    fi
    for app in "${tx_new_apps[@]}"; do rm -rf "$TARGET_DIR/iMac ReVoyage $app.app" || return 1; done
    tx_new_apps=()
    for label in "${tx_new_agents[@]}"; do rm -f "$AGENTS/$label.plist" || return 1; done
    tx_new_agents=()
    for app in "${tx_apps[@]}"; do
        if [[ -e "$STAGE/backup-apps/iMac ReVoyage $app.app" ]]; then
            mv "$STAGE/backup-apps/iMac ReVoyage $app.app" "$TARGET_DIR/" || return 1
        fi
    done
    for label in "${tx_labels[@]}"; do
        if [[ -e "$STAGE/backup-agents/$label.plist" ]]; then
            mv "$STAGE/backup-agents/$label.plist" "$AGENTS/" || return 1
        fi
    done
    if [[ "${REVOYAGE_DRY_RUN:-0}" != 1 ]]; then
        for label in "${tx_running[@]}"; do
            launchctl bootstrap "gui/$UID_NUMBER" "$AGENTS/$label.plist" || return 1
        done
    fi
    tx_active=0
}
finish() {
    local result=$?
    if ! rollback; then
        echo "恢复失败，旧文件保留在：$STAGE；请恢复文件并重新启动服务。" >&2
        exit 1
    fi
    rm -rf "$STAGE"
    exit "$result"
}
trap finish EXIT
trap 'exit 130' INT
trap 'exit 143' TERM HUP

plist_string() {
    local plist="$1" key="$2" value="$3"
    value="${value//\\/\\\\}"
    value="${value//\"/\\\"}"
    /usr/libexec/PlistBuddy -c "Add $key string \"$value\"" "$plist"
}

stage_app() {
    local app="$1" label="$2" executable="$3" flag="${4:-}"
    local log_stem="${label#re.voyage.}"
    [[ "$label" != re.voyage.receiver ]] || log_stem=network
    ditto "$PACKAGE_DIR/iMac ReVoyage $app.app" "$STAGE/apps/iMac ReVoyage $app.app" || return 1
    [[ -x "$STAGE/apps/iMac ReVoyage $app.app/Contents/MacOS/$executable" ]] || return 1
    # AirDrop/Finder can attach quarantine or resource-fork attributes. Clean
    # only our staged copy, before validating or touching the running install.
    local bundle="$STAGE/apps/iMac ReVoyage $app.app"
    xattr -cr "$bundle" || return 1
    if [[ "${REVOYAGE_DRY_RUN:-0}" != 1 ]]; then
        if ! codesign --verify --deep --strict "$bundle"; then
            echo "$app 的开发签名不可用，正在此 iMac 上重新生成本地签名…"
            codesign --force --deep --sign - --timestamp=none "$bundle" || {
                echo "$app 本地签名失败；原有安装保持不变。" >&2; return 1;
            }
            codesign --verify --deep --strict "$bundle" || return 1
        fi
    fi
    local plist="$STAGE/agents/$label.plist"
    /usr/libexec/PlistBuddy -c 'Clear dict' "$plist" >/dev/null || return 1
    /usr/libexec/PlistBuddy -c "Add :Label string $label" \
        -c 'Add :ProgramArguments array' \
        -c 'Add :RunAtLoad bool true' -c 'Add :KeepAlive bool true' \
        -c 'Add :ThrottleInterval integer 10' -c 'Add :LimitLoadToSessionType string Aqua' "$plist" || return 1
    plist_string "$plist" :ProgramArguments:0 "$TARGET_DIR/iMac ReVoyage $app.app/Contents/MacOS/$executable" || return 1
    plist_string "$plist" :StandardOutPath "$LOGS/$log_stem.out.log" || return 1
    plist_string "$plist" :StandardErrorPath "$LOGS/$log_stem.err.log" || return 1
    if [[ -n "$flag" ]]; then
        plist_string "$plist" :ProgramArguments:1 "$flag" || return 1
    fi
    plutil -lint "$plist" || return 1
}

# Validate the full core before touching an existing running installation.
stage_app Rescue re.voyage.rescue RescueReceiver
stage_app Receiver re.voyage.receiver TargetBridgeReceiver --appliance
stage_app 'Storage Watcher' re.voyage.storage StorageWatcher
updater_ready=0
if [[ -x "$STAGE/apps/iMac ReVoyage Receiver.app/Contents/MacOS/ReVoyageReceiverUpdater" ]]; then
    cp "$STAGE/agents/re.voyage.receiver.plist" "$STAGE/agents/re.voyage.updater.plist"
    /usr/libexec/PlistBuddy -c 'Set :Label re.voyage.updater' -c 'Delete :ProgramArguments:1' "$STAGE/agents/re.voyage.updater.plist"
    /usr/libexec/PlistBuddy -c 'Delete :ProgramArguments:0' -c 'Delete :StandardOutPath' -c 'Delete :StandardErrorPath' "$STAGE/agents/re.voyage.updater.plist"
    plist_string "$STAGE/agents/re.voyage.updater.plist" :ProgramArguments:0 "$TARGET_DIR/iMac ReVoyage Receiver.app/Contents/MacOS/ReVoyageReceiverUpdater"
    plist_string "$STAGE/agents/re.voyage.updater.plist" :StandardOutPath "$LOGS/updater.out.log"
    plist_string "$STAGE/agents/re.voyage.updater.plist" :StandardErrorPath "$LOGS/updater.err.log"
    updater_ready=1
fi
[[ "$REMOTE_UPDATE" == 0 || "$updater_ready" == 1 ]] || { echo "远程更新包缺少更新服务，保留原有安装。" >&2; exit 1; }
media_ready=0
if [[ -d "$PACKAGE_DIR/iMac ReVoyage Media Bridge.app" ]]; then
    if stage_app 'Media Bridge' re.voyage.media ReVoyageMediaBridge; then media_ready=1
    else echo "设备共享模块准备失败；继续安装核心显示和 HDMI Rescue，保留旧媒体模块。" >&2
    fi
fi

if [[ "${REVOYAGE_DRY_RUN:-0}" != 1 ]]; then
    SETTINGS_DIR="$INSTALL_HOME/Library/Application Support/TargetBridge Receiver"
    mkdir -p "$SETTINGS_DIR"
    ID_FILE="$SETTINGS_DIR/receiver.id"
    [[ ! -L "$ID_FILE" ]] || { echo "拒绝符号链接身份文件。" >&2; exit 1; }
    if [[ ! -e "$ID_FILE" ]]; then
        ID_TEMP="$(mktemp "$SETTINGS_DIR/.identity.XXXXXX")"
        uuidgen | tr '[:upper:]' '[:lower:]' > "$ID_TEMP"
        chmod 600 "$ID_TEMP"
        # Publish a complete file without replacing a concurrently generated ID.
        ln "$ID_TEMP" "$ID_FILE" || [[ -f "$ID_FILE" && ! -L "$ID_FILE" ]]
        rm -f "$ID_TEMP"
    fi
    RECEIVER_ID="$(tr -d '\r\n' < "$ID_FILE")"
    [[ "$RECEIVER_ID" =~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' ]] || {
        echo "Receiver 身份文件无效；原有服务保持运行。" >&2; exit 1;
    }
    chmod 600 "$ID_FILE"

fi

commit_group() {
    tx_active=1
    tx_running=(); tx_stopped=(); tx_new_apps=(); tx_new_agents=()
    local app label
    if [[ "${REVOYAGE_DRY_RUN:-0}" != 1 ]]; then
        for label in "${tx_labels[@]}"; do
            # The updater is our caller and must retain its socket/receipt until
            # the transaction completes. It restarts itself after replying.
            if [[ "$REMOTE_UPDATE" == 1 && "$label" == re.voyage.updater ]]; then
                launchctl print "gui/$UID_NUMBER/$label" >/dev/null 2>&1 || return 1
                continue
            fi
            if launchctl print "gui/$UID_NUMBER/$label" >/dev/null 2>&1; then
                [[ -f "$AGENTS/$label.plist" ]] || return 1
                launchctl bootout "gui/$UID_NUMBER/$label" || return 1
                tx_running+=("$label")
            fi
            tx_stopped+=("$label")
        done
    fi
    for app in "${tx_apps[@]}"; do
        if [[ -e "$TARGET_DIR/iMac ReVoyage $app.app" ]]; then
            mv "$TARGET_DIR/iMac ReVoyage $app.app" "$STAGE/backup-apps/" || return 1
        fi
        # Record before mutation so a failed or interrupted copy can be removed.
        tx_new_apps+=("$app")
        mv "$STAGE/apps/iMac ReVoyage $app.app" "$TARGET_DIR/" || return 1
    done
    for label in "${tx_labels[@]}"; do
        if [[ -e "$AGENTS/$label.plist" ]]; then mv "$AGENTS/$label.plist" "$STAGE/backup-agents/" || return 1; fi
        tx_new_agents+=("$label")
        mv "$STAGE/agents/$label.plist" "$AGENTS/" || return 1
    done
    if [[ "${REVOYAGE_DRY_RUN:-0}" != 1 ]]; then
        for label in "${tx_labels[@]}"; do
            [[ "$REMOTE_UPDATE" != 1 || "$label" != re.voyage.updater ]] || continue
            launchctl bootstrap "gui/$UID_NUMBER" "$AGENTS/$label.plist" || return 1
        done
    fi
    tx_active=0
    return 0
}

tx_apps=(Rescue Receiver 'Storage Watcher')
tx_labels=(re.voyage.rescue re.voyage.receiver re.voyage.storage)
[[ "$updater_ready" == 0 ]] || tx_labels+=(re.voyage.updater)
commit_group || { echo "核心升级失败，正在恢复原有安装与服务。" >&2; exit 1; }
if [[ "$media_ready" == 1 ]]; then
    tx_apps=('Media Bridge'); tx_labels=(re.voyage.media)
    if ! commit_group; then
        echo "设备共享模块升级失败，正在恢复旧媒体模块；核心显示和 HDMI Rescue 已安装。" >&2
        rollback || exit 1
    fi
fi

if [[ "${REVOYAGE_DRY_RUN:-0}" == 1 ]]; then
    echo "Dry run: apps copied and LaunchAgent plists validated; services not started."
else
    if [[ "$REMOTE_UPDATE" == 0 ]]; then
        enable_receiver_ssh || echo "SSH 设置未完成；稍后可单独重试，无需重新安装应用。" >&2
    else
        echo "远程更新保留 macOS 现有 SSH 设置，不请求本机管理员授权。"
    fi
    echo "安装完成。登录后自动启动，崩溃后尝试重启。"
    echo "当前开发版使用本地有线直连，无需配对码或导入配对文件。"
    echo "日志目录：$LOGS"
    echo "设备共享仅在请求时采集；首次使用请允许摄像头和麦克风访问。"
fi
