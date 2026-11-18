#!/usr/bin/env bash
# Realm TCP/UDP Forwarding Panel
set -u
CURRENT_VERSION="0.5.0"
PANEL_SHA="8390110a9f4aa532c0771ce420755a81f8a8a5b167da16b04ac830020aae1082"
RAW="https://raw.githubusercontent.com/Banezzz/Realm-TCP-UDP-Forwarding-Panel"
API="https://api.github.com/repos/Banezzz/Realm-TCP-UDP-Forwarding-Panel"
REALM_DIR=/root/realm
LOG_FILE=/var/log/realm_manager.log
PROXY_CONFIG_FILE="$REALM_DIR/.proxy_config"
PROXY=""
script=$(realpath -- "$0") || exit 1
panel="$(dirname -- "$script")/panel.py"
skip_update=false
skip_proxy=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --no-update) skip_update=true; shift ;;
        --no-proxy) skip_proxy=true; shift ;;
        *) break ;;
    esac
done
if [[ ${1:-} == --help ]]; then
    echo "realm.sh [--no-update] [--no-proxy] [create|list|delete|migrate|apply|export|import|install] [参数]"
    echo "示例  realm.sh migrate all nftables"
    exit 0
fi
if (( EUID != 0 )); then
    echo "请用 root 运行。" >&2
    exit 1
fi
umask 077
mkdir -p "$REALM_DIR" || exit 1
if ! $skip_proxy && [[ -s $PROXY_CONFIG_FILE ]]; then
    PROXY=$(cat "$PROXY_CONFIG_FILE")
fi
export REALM_DOWNLOAD_PROXY="$PROXY"

dependencies() {
    if [[ -x /usr/bin/python3 ]] && /usr/bin/python3 -c 'import sys,tomlkit; assert sys.version_info >= (3,8)' 2>/dev/null && command -v curl ip ss >/dev/null; then
        return 0
    fi
    if command -v apt-get >/dev/null; then
        apt-get update && apt-get install -y python3 python3-tomlkit curl iproute2
    elif command -v dnf >/dev/null; then
        dnf install -y python3 python3-tomlkit curl iproute
    elif command -v pacman >/dev/null; then
        pacman -S --needed --noconfirm python python-tomlkit curl iproute2
    else
        echo "请为 /usr/bin/python3 安装 Python 3.8+、tomlkit、curl 和 iproute2。" >&2
        return 1
    fi
    /usr/bin/python3 -c 'import sys,tomlkit; assert sys.version_info >= (3,8)' && command -v curl ip ss >/dev/null
}

verified() {
    [[ -f $1 ]] && [[ $(sha256sum -- "$1" | cut -d' ' -f1) == "$PANEL_SHA" ]]
}

get_panel() {
    verified "$panel" && return
    # Single-file bootstrap. Bind the companion to the exact launcher digest.
    panel="$REALM_DIR/panel-$PANEL_SHA.py"
    verified "$panel" && return
    local tmp
    tmp=$(mktemp "$REALM_DIR/.panel.XXXXXX") || return 1
    if curl -fLsS --max-time 60 "${PROXY}${RAW}/main/panel.py" -o "$tmp" && verified "$tmp"; then
        mv -f -- "$tmp" "$panel"
    else
        rm -f -- "$tmp"
        echo "组件校验失败。请从同一提交下载 realm.sh 和 panel.py。" >&2
        return 1
    fi
}

check_update() {
    local ver head tmp companion digest oid actual confirm
    local restart_args=(--no-update)
    $skip_proxy && restart_args+=(--no-proxy)
    ver=$(curl -fLsS --max-time 5 "$RAW/main/version.txt") || return 0
    [[ $ver =~ ^[0-9]+\.[0-9]+\.[0-9]+$ && $ver != "$CURRENT_VERSION" ]] || return 0
    [[ $(printf '%s\n' "$ver" "$CURRENT_VERSION" | sort -V | tail -1) == "$ver" ]] || return 0
    read -rp "面板 $ver 可用，更新？[y/N] " confirm
    [[ $confirm == [yY] ]] || return 0
    head=$(curl -fLsS --max-time 15 "$API/commits/main" | /usr/bin/python3 -c 'import sys,json;print(json.load(sys.stdin)["sha"])') || return 1
    [[ $head =~ ^[a-f0-9]{40}$ ]] || return 1
    tmp=$(mktemp "$(dirname "$script")/.realm-update.XXXXXX") || return 1
    companion=$(mktemp "$REALM_DIR/.panel.XXXXXX") || { rm -f -- "$tmp"; return 1; }
    oid=$(curl -fLsS --max-time 15 "$API/contents/realm.sh?ref=$head" |
        /usr/bin/python3 -c 'import sys,json; print(json.load(sys.stdin)["sha"])') || oid=""
    if [[ $oid =~ ^[a-f0-9]{40}$ ]] && curl -fLsS --max-time 30 "$RAW/$head/realm.sh" -o "$tmp"; then
        actual=$(/usr/bin/python3 -c 'import hashlib,pathlib,sys; b=pathlib.Path(sys.argv[1]).read_bytes(); print(hashlib.sha1(b"blob "+str(len(b)).encode()+bytes(1)+b).hexdigest())' "$tmp")
        digest=$(sed -nE 's/^PANEL_SHA="([0-9a-f]{64})"$/\1/p' "$tmp")
        if [[ $actual == "$oid" && $digest =~ ^[a-f0-9]{64}$ ]] && bash -n "$tmp" &&
            grep -Fxq "CURRENT_VERSION=\"$ver\"" "$tmp" &&
            curl -fLsS --max-time 30 "${PROXY}$RAW/$head/panel.py" -o "$companion" &&
            [[ $(sha256sum -- "$companion" | cut -d' ' -f1) == "$digest" ]] &&
            mv -f -- "$companion" "$REALM_DIR/panel-$digest.py" && chmod 755 "$tmp" && mv -f -- "$tmp" "$script"; then
            exec "$script" "${restart_args[@]}" "$@"
        fi
    fi
    rm -f -- "$tmp" "$companion"
    return 1
}

manage_proxy() {
    local url
    read -rp "GitHub 下载反代 URL（留空直连） " url
    if [[ -n $url && $url != https://* ]]; then
        echo "反代需要 HTTPS。"
        return 1
    fi
    PROXY=${url:+${url%/}/}
    printf '%s\n' "$PROXY" > "$PROXY_CONFIG_FILE"
    export REALM_DOWNLOAD_PROXY="$PROXY"
}
manage_cron() {
    local choice hour
    read -rp "1 设置每日重启  2 取消  3 查看  " choice
    case "$choice" in
        1) read -rp "小时 (0-23) " hour
           [[ $hour =~ ^([0-9]|1[0-9]|2[0-3])$ ]] || return 1
           manager cron-clean && echo "0 $hour * * * root /usr/bin/systemctl restart realm" >> /etc/crontab ;;
        2) manager cron-clean ;;
        3) grep -E '^0 [0-9]{1,2} \* \* \* root /usr/bin/systemctl restart realm$' /etc/crontab || true ;;
    esac
}
manager() {
    /usr/bin/python3 "$panel" "$@" || return $?
    printf '%s %s\n' "$(date -Is)" "$1" >> "$LOG_FILE"
}

dependencies && get_panel || exit 1
if (( $# > 0 )); then
    manager "$@"
    exit $?
fi
if ! $skip_proxy && [[ ! -e $PROXY_CONFIG_FILE && -t 0 ]]; then
    country=$(curl -fsSL --max-time 3 https://ipinfo.io/country 2>/dev/null || true)
    if [[ $country == CN ]]; then
        read -rp "检测到中国网络，设置 GitHub 下载反代？[y/N] " choice
        [[ $choice != [yY] ]] || manage_proxy
    fi
fi
$skip_update || check_update
while true; do
    printf '\nRealm TCP/UDP 转发面板 %s\n' "$CURRENT_VERSION"
    echo ' 1 安装/更新 Realm        2 创建转发（单条或批量）'
    echo ' 3 全部转发规则           4 删除规则'
    echo ' 5 启动 Realm             6 停止 Realm             7 重启 Realm'
    echo ' 8 定时重启               9 操作与服务日志        10 卸载'
    echo '11 下载代理              12 配置导入/导出         13 Realm DNS'
    echo '14 重新应用 / 刷新 NAT 域名     15 一键迁移后端     0 退出'
    read -rp "选项 " choice || exit
    case "$choice" in
        1) manager install ;;
        2) manager create ;;
        3) manager list ;;
        4) manager delete ;;
        5) systemctl enable --now realm.service ;;
        6) systemctl stop realm.service ;;
        7) systemctl restart realm.service ;;
        8) manage_cron ;;
        9) tail -n 20 "$LOG_FILE"; journalctl -u realm.service -u realm-panel-nat.service -n 50 --no-pager ;;
        10) manager uninstall; exit $? ;;
        11) manage_proxy ;;
        12) read -rp "1 导出  2 导入  " choice
            case "$choice" in 1) manager export ;; 2) manager import ;; esac ;;
        13) manager dns ;;
        14) manager apply ;;
        15) manager migrate ;;
        0) exit ;;
        *) echo "无效选项" ;;
    esac
done
