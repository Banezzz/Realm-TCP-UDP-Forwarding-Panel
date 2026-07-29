#!/bin/bash

# ========================================
# 全局配置
# ========================================
CURRENT_VERSION="0.5.0"
REALM_DIR="/root/realm"
CONFIG_FILE="$REALM_DIR/config.toml"
SERVICE_FILE="/etc/systemd/system/realm.service"
LOG_FILE="/var/log/realm_manager.log"
PROXY_CONFIG_FILE="$REALM_DIR/.proxy_config"

# iptables 转发配置
IPTABLES_DIR="/root/iptables-forward"
IPTABLES_RULES_FILE="$IPTABLES_DIR/rules.conf"
IPTABLES_SERVICE_FILE="/etc/systemd/system/iptables-forward.service"
IPTABLES_CHAIN="IPT-FORWARD"

# 转发方式切换备份目录
SWITCH_BACKUP_DIR="$REALM_DIR/switch-backups"

# 代理变量（初始为空）
PROXY=""

# GitHub 相关 URL（将在代理配置后设置）
BASE_RAW_URL="https://raw.githubusercontent.com/Banezzz/Realm-TCP-UDP-Forwarding-Panel/main"
BASE_GITHUB_URL="https://github.com"
UPDATE_URL=""
VERSION_CHECK_URL=""

# ========================================
# 颜色定义
# ========================================
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# ========================================
# 地址验证函数（支持IP和域名）
# ========================================
validate_remote_addr() {
    local addr="$1"
    # IPv4 地址
    if [[ "$addr" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        return 0
    fi
    # IPv6 地址（可带方括号）
    if [[ "$addr" =~ ^\[?[0-9a-fA-F:]+\]?$ ]]; then
        return 0
    fi
    # 域名（允许字母、数字、连字符、点号）
    if [[ "$addr" =~ ^[a-zA-Z0-9]([a-zA-Z0-9.-]*[a-zA-Z0-9])?$ ]] && [[ "$addr" == *.* ]]; then
        return 0
    fi
    return 1
}

is_domain_name() {
    local addr="$1"
    # 如果包含字母且含有点号，认为是域名
    if [[ "$addr" =~ [a-zA-Z] ]] && [[ "$addr" == *.* ]]; then
        return 0
    fi
    return 1
}

# ========================================
# URL 初始化函数
# ========================================
init_urls() {
    UPDATE_URL="${PROXY}${BASE_RAW_URL}/realm.sh"
    VERSION_CHECK_URL="${PROXY}${BASE_RAW_URL}/version.txt"
}

# ========================================
# 中国 IP 检测
# ========================================
check_china_ip() {
    local country=""

    # 尝试多个 IP 检测服务
    # 方法1: ip-api.com
    country=$(curl -sL --connect-timeout 5 "http://ip-api.com/line?fields=countryCode" 2>/dev/null | head -n1)

    # 方法2: ipinfo.io (备用)
    if [[ -z "$country" ]]; then
        country=$(curl -sL --connect-timeout 5 "https://ipinfo.io/country" 2>/dev/null | head -n1)
    fi

    # 方法3: ipapi.co (备用)
    if [[ -z "$country" ]]; then
        country=$(curl -sL --connect-timeout 5 "https://ipapi.co/country_code" 2>/dev/null | head -n1)
    fi

    # 判断是否为中国
    if [[ "$country" == "CN" ]]; then
        return 0  # 在中国
    else
        return 1  # 不在中国
    fi
}

# ========================================
# 代理配置
# ========================================
setup_proxy() {
    echo -e "\n${BLUE}▶ 正在检测网络环境...${NC}"

    # 确保目录存在
    mkdir -p "$REALM_DIR"

    # 检查是否已有保存的代理配置
    if [[ -f "$PROXY_CONFIG_FILE" ]]; then
        local saved_proxy
        saved_proxy=$(cat "$PROXY_CONFIG_FILE" 2>/dev/null)
        if [[ -n "$saved_proxy" ]]; then
            echo -e "${GREEN}✓ 检测到已保存的代理配置${NC}"
            echo -e "  代理地址: ${CYAN}${saved_proxy}${NC}"
            read -rp "是否使用此代理？(Y/n): " use_saved
            use_saved=${use_saved:-Y}
            if [[ "$use_saved" =~ ^[Yy]$ ]]; then
                PROXY="$saved_proxy"
                init_urls
                echo -e "${GREEN}✓ 已启用代理${NC}"
                return 0
            fi
        fi
    fi

    # 检测是否在中国
    if check_china_ip; then
        echo -e "${YELLOW}⚠ 检测到您的 IP 位于中国大陆${NC}"
        echo -e "${YELLOW}  由于网络原因，访问 GitHub 可能较慢或失败${NC}"
        echo -e ""
        read -rp "是否配置 GitHub 反代加速？(Y/n): " use_proxy
        use_proxy=${use_proxy:-Y}

        if [[ "$use_proxy" =~ ^[Yy]$ ]]; then
            echo -e ""
            echo -e "${BLUE}请输入反代地址（直接回车使用默认值）${NC}"
            echo -e "${CYAN}默认反代: https://acc.banez.de/${NC}"
            echo -e "${YELLOW}提示: 反代地址格式应为 https://xxx.xxx/ (末尾带斜杠)${NC}"
            echo -e ""
            read -rp "反代地址: " custom_proxy

            # 使用默认值或用户输入
            if [[ -z "$custom_proxy" ]]; then
                PROXY="https://acc.banez.de/"
            else
                # 确保地址末尾有斜杠
                if [[ ! "$custom_proxy" =~ /$ ]]; then
                    custom_proxy="${custom_proxy}/"
                fi
                PROXY="$custom_proxy"
            fi

            echo -e ""
            echo -e "${BLUE}▶ 正在测试代理连接...${NC}"

            # 测试代理是否可用
            if curl -sL --connect-timeout 10 "${PROXY}https://raw.githubusercontent.com/Banezzz/Realm-TCP-UDP-Forwarding-Panel/main/version.txt" &>/dev/null; then
                echo -e "${GREEN}✓ 代理连接成功！${NC}"

                # 询问是否保存配置
                read -rp "是否保存此代理配置？(Y/n): " save_config
                save_config=${save_config:-Y}
                if [[ "$save_config" =~ ^[Yy]$ ]]; then
                    echo "$PROXY" > "$PROXY_CONFIG_FILE"
                    echo -e "${GREEN}✓ 代理配置已保存${NC}"
                fi
            else
                echo -e "${YELLOW}⚠ 代理连接测试失败，但仍将尝试使用${NC}"
                echo -e "${YELLOW}  如果后续下载失败，请检查代理地址是否正确${NC}"
            fi

            init_urls
            echo -e "${GREEN}✓ 已配置代理: ${PROXY}${NC}"
        else
            echo -e "${YELLOW}▶ 将直接连接 GitHub（可能较慢）${NC}"
            init_urls
        fi
    else
        echo -e "${GREEN}✓ 网络环境正常，无需配置代理${NC}"
        init_urls
    fi
}

# ========================================
# 清除代理配置
# ========================================
clear_proxy_config() {
    if [[ -f "$PROXY_CONFIG_FILE" ]]; then
        rm -f "$PROXY_CONFIG_FILE"
        PROXY=""
        init_urls
        echo -e "${GREEN}✓ 代理配置已清除${NC}"
    else
        echo -e "${YELLOW}▶ 没有保存的代理配置${NC}"
    fi
}

# ========================================
# 代理管理菜单
# ========================================
manage_proxy() {
    echo -e "\n${YELLOW}代理设置管理：${NC}"
    echo -e ""

    # 显示当前状态
    if [[ -n "$PROXY" ]]; then
        echo -e "当前代理: ${GREEN}${PROXY}${NC}"
    else
        echo -e "当前代理: ${YELLOW}未配置${NC}"
    fi

    if [[ -f "$PROXY_CONFIG_FILE" ]]; then
        echo -e "已保存配置: ${CYAN}$(cat "$PROXY_CONFIG_FILE")${NC}"
    fi

    echo -e ""
    echo "1. 重新配置代理"
    echo "2. 手动输入代理地址"
    echo "3. 清除代理配置"
    echo "4. 测试当前代理"
    echo "0. 返回主菜单"
    echo -e ""
    read -rp "请选择: " choice

    case $choice in
        1)
            # 强制重新检测并配置
            PROXY=""
            rm -f "$PROXY_CONFIG_FILE" 2>/dev/null
            setup_proxy
            ;;
        2)
            echo -e ""
            echo -e "${BLUE}请输入反代地址${NC}"
            echo -e "${YELLOW}提示: 反代地址格式应为 https://xxx.xxx/ (末尾带斜杠)${NC}"
            echo -e "${CYAN}示例: https://acc.banez.de/${NC}"
            echo -e ""
            read -rp "反代地址: " custom_proxy

            if [[ -z "$custom_proxy" ]]; then
                echo -e "${RED}✖ 未输入地址${NC}"
                return
            fi

            # 确保地址末尾有斜杠
            if [[ ! "$custom_proxy" =~ /$ ]]; then
                custom_proxy="${custom_proxy}/"
            fi

            PROXY="$custom_proxy"
            init_urls

            # 测试代理
            echo -e "${BLUE}▶ 正在测试代理连接...${NC}"
            if curl -sL --connect-timeout 10 "${PROXY}https://raw.githubusercontent.com/Banezzz/Realm-TCP-UDP-Forwarding-Panel/main/version.txt" &>/dev/null; then
                echo -e "${GREEN}✓ 代理连接成功！${NC}"
                read -rp "是否保存此代理配置？(Y/n): " save_config
                save_config=${save_config:-Y}
                if [[ "$save_config" =~ ^[Yy]$ ]]; then
                    echo "$PROXY" > "$PROXY_CONFIG_FILE"
                    echo -e "${GREEN}✓ 代理配置已保存${NC}"
                fi
            else
                echo -e "${YELLOW}⚠ 代理连接测试失败，但已设置${NC}"
            fi
            ;;
        3)
            clear_proxy_config
            ;;
        4)
            if [[ -z "$PROXY" ]]; then
                echo -e "${YELLOW}▶ 当前未配置代理，测试直连...${NC}"
                if curl -sL --connect-timeout 10 "https://raw.githubusercontent.com/Banezzz/Realm-TCP-UDP-Forwarding-Panel/main/version.txt" &>/dev/null; then
                    echo -e "${GREEN}✓ 直连 GitHub 成功${NC}"
                else
                    echo -e "${RED}✖ 直连 GitHub 失败，建议配置代理${NC}"
                fi
            else
                echo -e "${BLUE}▶ 测试代理: ${PROXY}${NC}"
                if curl -sL --connect-timeout 10 "${PROXY}https://raw.githubusercontent.com/Banezzz/Realm-TCP-UDP-Forwarding-Panel/main/version.txt" &>/dev/null; then
                    echo -e "${GREEN}✓ 代理连接成功${NC}"
                else
                    echo -e "${RED}✖ 代理连接失败${NC}"
                fi
            fi
            ;;
        0|*)
            return
            ;;
    esac
}

# ========================================
# 初始化检查
# ========================================
init_check() {
    # 检查root权限
    if [[ $EUID -ne 0 ]]; then
        echo -e "${RED}✖ 必须使用root权限运行本脚本${NC}"
        exit 1
    fi

    # 检查并安装必要工具
    local missing_tools=()

    if ! command -v curl &> /dev/null; then
        missing_tools+=("curl")
    fi
    if ! command -v wget &> /dev/null; then
        missing_tools+=("wget")
    fi

    if [ ${#missing_tools[@]} -gt 0 ]; then
        echo -e "${YELLOW}▶ 正在安装必要工具: ${missing_tools[*]}...${NC}"
        if command -v apt-get &> /dev/null; then
            apt-get update && apt-get install -y "${missing_tools[@]}"
        elif command -v yum &> /dev/null; then
            yum install -y "${missing_tools[@]}"
        elif command -v dnf &> /dev/null; then
            dnf install -y "${missing_tools[@]}"
        elif command -v pacman &> /dev/null; then
            pacman -Sy --noconfirm "${missing_tools[@]}"
        else
            echo -e "${RED}✖ 无法自动安装工具，请手动安装: ${missing_tools[*]}${NC}"
            exit 1
        fi
    fi

    # 创建必要目录
    mkdir -p "$REALM_DIR"
    if [[ ! -w $(dirname "$LOG_FILE") ]]; then
        echo -e "${RED}✖ 日志目录不可写，请检查权限${NC}"
        exit 1
    fi
    touch "$LOG_FILE" || {
        echo -e "${RED}✖ 无法创建日志文件${NC}"
        exit 1
    }

    log "脚本启动 v$CURRENT_VERSION"
}

# ========================================
# 日志系统
# ========================================
log() {
    local log_msg="[$(date '+%Y-%m-%d %H:%M:%S')] $1"
    echo -e "$log_msg" >> "$LOG_FILE"
}

# ========================================
# 版本比较函数
# ========================================
version_compare() {
    if [[ "$1" == "$2" ]]; then
        return 0  # 版本相同
    fi
    local IFS=.
    local i ver1=($1) ver2=($2)
    for ((i=0; i<${#ver1[@]}; i++)); do
        if [[ -z ${ver2[i]} ]]; then
            ver2[i]=0
        fi
        if ((10#${ver1[i]} > 10#${ver2[i]})); then
            return 1  # 当前版本更高
        fi
        if ((10#${ver1[i]} < 10#${ver2[i]})); then
            return 2  # 远程版本更高
        fi
    done
    return 0
}

# ========================================
# 自动更新模块
# ========================================
check_update() {
    echo -e "\n${BLUE}▶ 正在检查更新...${NC}"
    
    # 获取远程版本（更严格的过滤）
    remote_version=$(curl -sL $VERSION_CHECK_URL 2>> "$LOG_FILE" | head -n1 | sed 's/[^0-9.]//g')
    if [[ -z "$remote_version" ]]; then
        log "版本检查失败：无法获取远程版本"
        echo -e "${RED}✖ 无法获取远程版本信息，请检查网络连接${NC}"
        return 1
    fi
    
    # 验证版本号格式
    if ! [[ "$remote_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        log "版本检查失败：无效的远程版本号 '$remote_version'"
        echo -e "${RED}✖ 远程版本号格式错误${NC}"
        return 1
    fi

    # 版本比较
    version_compare "$CURRENT_VERSION" "$remote_version"
    case $? in
        0)
            echo -e "${GREEN}✓ 当前已是最新版本 v${CURRENT_VERSION}${NC}"
            return 1
            ;;
        1)
            echo -e "${YELLOW}⚠ 本地版本 v${CURRENT_VERSION} 比远程版本 v${remote_version} 更高${NC}"
            return 1
            ;;
        2)
            echo -e "${YELLOW}▶ 发现新版本 v${remote_version}${NC}"
            return 0
            ;;
    esac
}

perform_update() {
    echo -e "${BLUE}▶ 开始更新...${NC}"
    log "尝试从 $UPDATE_URL 下载更新"
    
    # 下载临时文件
    if ! curl -sL $UPDATE_URL -o "$0.tmp"; then
        log "更新失败：下载脚本失败"
        echo -e "${RED}✖ 下载更新失败，请检查网络${NC}"
        return 1
    fi
    
    # 验证下载内容
    if ! grep -q "CURRENT_VERSION" "$0.tmp"; then
        log "更新失败：下载文件无效"
        echo -e "${RED}✖ 下载文件校验失败${NC}"
        rm -f "$0.tmp"
        return 1
    fi
    
    # 替换脚本
    chmod +x "$0.tmp"
    mv -f "$0.tmp" "$0"
    log "更新完成，重启脚本"
    
    echo -e "${GREEN}✓ 更新成功，重新启动脚本...${NC}"
    # 传递参数跳过更新检查
    exec "$0" "--no-update" "$@"
}

# ========================================
# 架构检测
# ========================================
detect_arch() {
    local arch
    arch=$(uname -m)
    case "$arch" in
        x86_64|amd64)
            echo "x86_64-unknown-linux-gnu"
            ;;
        aarch64|arm64)
            echo "aarch64-unknown-linux-gnu"
            ;;
        armv7l|armhf)
            echo "armv7-unknown-linux-gnueabihf"
            ;;
        *)
            echo ""
            ;;
    esac
}

# ========================================
# 获取已安装的 Realm 版本
# ========================================
get_installed_version() {
    if [[ -x "$REALM_DIR/realm" ]]; then
        "$REALM_DIR/realm" --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -n1
    else
        echo ""
    fi
}

# ========================================
# 核心功能模块
# ========================================
deploy_realm() {
    log "开始安装Realm"
    echo -e "${BLUE}▶ 正在安装Realm...${NC}"

    # 检测系统架构
    local arch_suffix
    arch_suffix=$(detect_arch)
    if [[ -z "$arch_suffix" ]]; then
        echo -e "${RED}✖ 不支持的系统架构: $(uname -m)${NC}"
        echo -e "${YELLOW}  支持的架构: x86_64, aarch64, armv7l${NC}"
        return 1
    fi
    echo -e "${GREEN}✓ 检测到系统架构: $(uname -m) → ${arch_suffix}${NC}"

    mkdir -p "$REALM_DIR"
    cd "$REALM_DIR" || exit 1

    # 获取最新版本号
    echo -e "${BLUE}▶ 正在检测最新版本...${NC}"
    LATEST_VERSION=$(curl -sL "${PROXY}https://github.com/zhboner/realm/releases" | grep -oE '/zhboner/realm/releases/tag/v[0-9]+\.[0-9]+\.[0-9]+' | head -n1 | cut -d'/' -f6 | tr -d 'v')

    # 版本号验证
    if [[ -z "$LATEST_VERSION" || ! "$LATEST_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        log "版本检测失败，使用备用版本2.7.0"
        LATEST_VERSION="2.7.0"
        echo -e "${YELLOW}⚠ 无法获取最新版本，使用备用版本 v${LATEST_VERSION}${NC}"
    else
        echo -e "${GREEN}✓ 检测到最新版本 v${LATEST_VERSION}${NC}"
    fi

    # 检查是否需要更新
    local installed_version
    installed_version=$(get_installed_version)
    if [[ -n "$installed_version" ]]; then
        echo -e "${CYAN}  当前已安装版本: v${installed_version}${NC}"
        if [[ "$installed_version" == "$LATEST_VERSION" ]]; then
            read -rp "已是最新版本，是否重新安装？(y/N): " reinstall
            if [[ ! "$reinstall" =~ ^[Yy]$ ]]; then
                echo "已取消安装。"
                return 0
            fi
        fi
    fi

    # 下载最新版本
    DOWNLOAD_URL="${PROXY}https://github.com/zhboner/realm/releases/download/v${LATEST_VERSION}/realm-${arch_suffix}.tar.gz"
    echo -e "${BLUE}▶ 正在下载 Realm v${LATEST_VERSION}...${NC}"
    if ! wget --show-progress -qO realm.tar.gz "$DOWNLOAD_URL"; then
        log "安装失败：下载错误"
        echo -e "${RED}✖ 文件下载失败，请检查：${NC}"
        echo -e "1. 网络连接状态"
        echo -e "2. GitHub访问权限"
        echo -e "3. 手动验证下载地址: $DOWNLOAD_URL"
        return 1
    fi

    # 解压安装
    tar -xzf realm.tar.gz
    chmod +x realm
    rm realm.tar.gz

    # 初始化配置文件
    if [ ! -f "$CONFIG_FILE" ]; then
        cat > "$CONFIG_FILE" <<'INITEOF'
[network]
no_tcp = false
use_udp = true

[dns]
mode = "ipv4_and_ipv6"
protocol = "tcp_and_udp"
nameservers = ["8.8.8.8:53", "8.8.4.4:53", "1.1.1.1:53", "1.0.0.1:53", "[2001:4860:4860::8888]:53", "[2606:4700:4700::1111]:53"]
min_ttl = 0
max_ttl = 300
cache_size = 256
INITEOF
    fi

    # 创建服务文件
    echo -e "${BLUE}▶ 创建系统服务...${NC}"
    cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=Realm Proxy Service
After=network.target

[Service]
Type=simple
ExecStart=$REALM_DIR/realm -c $CONFIG_FILE
Restart=always
User=root

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    log "安装成功"
    echo -e "${GREEN}✔ 安装完成！${NC}"
}

# 打印规则表头
print_rules_header() {
    echo -e "                   ${YELLOW}当前 Realm 转发规则${NC}                   "
    echo -e "${BLUE}---------------------------------------------------------------------------------------------------------${NC}${YELLOW}"
    printf "%-5s| %-30s| %-40s| %-20s\n" "序号" "   本地地址:端口 " "   目标地址:端口 " "备注"
    echo -e "${NC}${BLUE}---------------------------------------------------------------------------------------------------------${NC}"
}

# 查看转发规则
show_rules() {
    print_rules_header

    if [[ ! -f "$CONFIG_FILE" ]]; then
        echo -e "${YELLOW}配置文件不存在${NC}"
        return
    fi

    local IFS=$'\n'
    local lines=($(grep -n 'listen =' "$CONFIG_FILE" 2>/dev/null))

    if [ ${#lines[@]} -eq 0 ]; then
        echo -e "没有发现任何转发规则。"
        return
    fi

    local index=1
    for line in "${lines[@]}"; do
        local line_number=$(echo "$line" | cut -d ':' -f 1)
        local listen_info=$(sed -n "${line_number}p" "$CONFIG_FILE" | cut -d '"' -f 2)
        local remote_info=$(sed -n "$((line_number + 1))p" "$CONFIG_FILE" | cut -d '"' -f 2)
        local remark=$(sed -n "$((line_number-1))p" "$CONFIG_FILE" | grep "^# 备注:" | cut -d ':' -f 2)

        printf "%-4s| %-24s| %-34s| %-20s\n" " $index" "$listen_info" "$remote_info" "$remark"
        echo -e "${BLUE}---------------------------------------------------------------------------------------------------------${NC}"
        ((index++))
    done
}

# 添加转发规则（入口菜单）
add_rule() {
    log "添加转发规则"
    echo -e "\n${YELLOW}请选择添加方式：${NC}"
    echo "1) 单条添加"
    echo "2) 批量添加"
    read -rp "请输入选项 [1-2] (默认1): " add_mode
    add_mode=${add_mode:-1}

    case $add_mode in
        1) add_single_rule ;;
        2) batch_add_rules ;;
        *) echo -e "${RED}无效选项！${NC}" ;;
    esac
}

# 单条添加转发规则
add_single_rule() {
    while : ; do
        echo -e "\n${BLUE}▶ 添加新规则（输入 q 退出）${NC}"

        # 获取输入
        read -rp "本地监听端口: " local_port
        [ "$local_port" = "q" ] && break
        read -rp "目标服务器地址(IP或域名): " remote_addr
        read -rp "目标端口: " remote_port
        read -rp "规则备注: " remark

        # 输入验证
        if ! [[ "$local_port" =~ ^[0-9]+$ ]] || ! [[ "$remote_port" =~ ^[0-9]+$ ]]; then
            echo -e "${RED}✖ 端口必须为数字！${NC}"
            continue
        fi

        # 端口范围验证
        if (( local_port < 1 || local_port > 65535 )); then
            echo -e "${RED}✖ 本地端口必须在 1-65535 范围内！${NC}"
            continue
        fi
        if (( remote_port < 1 || remote_port > 65535 )); then
            echo -e "${RED}✖ 目标端口必须在 1-65535 范围内！${NC}"
            continue
        fi

        # 目标地址验证（支持IP和域名）
        if ! validate_remote_addr "$remote_addr"; then
            echo -e "${RED}✖ 无效的目标地址！请输入有效的IP或域名${NC}"
            continue
        fi

        # 域名提示
        if is_domain_name "$remote_addr"; then
            echo -e "${CYAN}ℹ 检测到域名地址，Realm 将自动进行 DNS 解析${NC}"
            # 检查配置中是否有 [dns] 段
            if [[ -f "$CONFIG_FILE" ]] && ! grep -q '^\[dns\]' "$CONFIG_FILE"; then
                echo -e "${YELLOW}⚠ 建议在主菜单 [13] 中配置 DNS 设置以优化域名解析${NC}"
            fi
        fi

        # 监听模式选择
        echo -e "\n${YELLOW}请选择监听模式：${NC}"
        echo "1) 双栈监听 [::]:${local_port} (默认)"
        echo "2) 仅IPv4监听 0.0.0.0:${local_port}"
        echo "3) 自定义监听地址"
        read -rp "请输入选项 [1-3] (默认1): " ip_choice
        ip_choice=${ip_choice:-1}

        case $ip_choice in
            1)
                listen_addr="[::]:$local_port"
                desc="双栈监听"
                ;;
            2)
                listen_addr="0.0.0.0:$local_port"
                desc="仅IPv4"
                ;;
            3)
                while : ; do
                    read -rp "请输入完整监听地址(格式如 0.0.0.0:80 或 [::]:443): " listen_addr
                    # 格式验证
                    if ! [[ "$listen_addr" =~ ^([0-9a-fA-F.:]+|\[.*\]):[0-9]+$ ]]; then
                        echo -e "${RED}✖ 格式错误！示例: 0.0.0.0:80 或 [::]:443${NC}"
                        continue
                    fi
                    break
                done
                desc="自定义监听"
                ;;
            *)
                echo -e "${RED}无效选择，使用默认值！${NC}"
                listen_addr="[::]:$local_port"
                desc="双栈监听"
                ;;
        esac

        # 写入配置文件
        cat >> "$CONFIG_FILE" <<EOF

[[endpoints]]
# 备注: $remark
listen = "$listen_addr"
remote = "$remote_addr:$remote_port"
EOF

        # 双栈提示
        if [ "$ip_choice" -eq 1 ]; then
            echo -e "\n${CYAN}ℹ 双栈监听需要确保：${NC}"
            echo -e "${CYAN}   - Realm 配置中 [network] 段的 ipv6_only = false${NC}"
            echo -e "${CYAN}   - 系统已启用 IPv6 双栈支持 (sysctl net.ipv6.bindv6only=0)${NC}"
        fi

        # 重启服务
        systemctl restart realm.service
        log "规则已添加: $listen_addr → $remote_addr:$remote_port"
        echo -e "${GREEN}✔ 添加成功！${NC}"

        read -rp "继续添加？(y/n): " cont
        [[ "$cont" != "y" ]] && break
    done
}

# 批量添加转发规则
batch_add_rules() {
    echo -e "\n${BLUE}▶ 批量添加转发规则${NC}"
    echo -e "${CYAN}格式: 本地端口,目标地址,目标端口[,备注][,监听模式]${NC}"
    echo -e "${CYAN}监听模式: 1=双栈(默认) 2=仅IPv4 3=仅IPv6${NC}"
    echo -e "${CYAN}每行一条规则，输入空行结束${NC}"
    echo -e ""
    echo -e "${YELLOW}示例:${NC}"
    echo -e "  8080,1.2.3.4,80,网站转发,1"
    echo -e "  9090,example.com,443,域名转发"
    echo -e "  7070,10.0.0.1,22,,2"
    echo -e ""

    local rules=()
    while true; do
        read -rp "> " line
        [[ -z "$line" ]] && break
        rules+=("$line")
    done

    if [[ ${#rules[@]} -eq 0 ]]; then
        echo -e "${YELLOW}未输入任何规则${NC}"
        return
    fi

    # 解析并验证所有规则
    local valid_rules=()
    local error_count=0

    for i in "${!rules[@]}"; do
        local line="${rules[$i]}"
        local line_num=$((i + 1))

        IFS=',' read -ra parts <<< "$line"

        local lport="${parts[0]// /}"
        local raddr="${parts[1]// /}"
        local rport="${parts[2]// /}"
        local remark="${parts[3]// /}"
        local mode="${parts[4]// /}"
        mode=${mode:-1}

        # 必填字段检查
        if [[ -z "$lport" || -z "$raddr" || -z "$rport" ]]; then
            echo -e "${RED}✖ 第${line_num}行: 缺少必填字段（本地端口,目标地址,目标端口）${NC}"
            ((error_count++))
            continue
        fi

        # 端口数字验证
        if ! [[ "$lport" =~ ^[0-9]+$ ]] || ! [[ "$rport" =~ ^[0-9]+$ ]]; then
            echo -e "${RED}✖ 第${line_num}行: 端口必须为数字${NC}"
            ((error_count++))
            continue
        fi

        # 端口范围验证
        if (( lport < 1 || lport > 65535 )); then
            echo -e "${RED}✖ 第${line_num}行: 本地端口必须在 1-65535 范围内${NC}"
            ((error_count++))
            continue
        fi
        if (( rport < 1 || rport > 65535 )); then
            echo -e "${RED}✖ 第${line_num}行: 目标端口必须在 1-65535 范围内${NC}"
            ((error_count++))
            continue
        fi

        # 目标地址验证
        if ! validate_remote_addr "$raddr"; then
            echo -e "${RED}✖ 第${line_num}行: 无效的目标地址${NC}"
            ((error_count++))
            continue
        fi

        # 监听模式验证
        if ! [[ "$mode" =~ ^[123]$ ]]; then
            echo -e "${RED}✖ 第${line_num}行: 监听模式必须为 1/2/3${NC}"
            ((error_count++))
            continue
        fi

        # 生成监听地址
        local listen_addr
        case $mode in
            1) listen_addr="[::]:$lport" ;;
            2) listen_addr="0.0.0.0:$lport" ;;
            3) listen_addr="[::]:$lport" ;;
        esac

        valid_rules+=("${listen_addr}|${raddr}:${rport}|${remark}")
    done

    if [[ ${#valid_rules[@]} -eq 0 ]]; then
        echo -e "${RED}✖ 没有有效的规则可添加${NC}"
        return
    fi

    # 存在错误时询问是否继续
    if (( error_count > 0 )); then
        echo -e "\n${YELLOW}⚠ ${error_count} 条规则有误，${#valid_rules[@]} 条有效，是否继续添加有效规则？${NC}"
        read -rp "(y/n): " cont
        [[ "$cont" != "y" ]] && return
    fi

    # 预览
    echo -e "\n${YELLOW}将添加以下 ${#valid_rules[@]} 条规则：${NC}"
    echo -e "${BLUE}──────────────────────────────────────────────────────────${NC}"
    printf "${YELLOW}%-4s %-24s %-30s %s${NC}\n" "序号" "监听地址" "目标地址" "备注"
    echo -e "${BLUE}──────────────────────────────────────────────────────────${NC}"
    local idx=1
    for rule in "${valid_rules[@]}"; do
        IFS='|' read -ra p <<< "$rule"
        printf "%-4s %-24s %-30s %s\n" " $idx" "${p[0]}" "${p[1]}" "${p[2]}"
        ((idx++))
    done
    echo -e "${BLUE}──────────────────────────────────────────────────────────${NC}"

    read -rp "确认添加？(y/n): " confirm
    [[ "$confirm" != "y" ]] && return

    # 写入配置
    for rule in "${valid_rules[@]}"; do
        IFS='|' read -ra p <<< "$rule"
        cat >> "$CONFIG_FILE" <<EOF

[[endpoints]]
# 备注: ${p[2]}
listen = "${p[0]}"
remote = "${p[1]}"
EOF
    done

    # 统一重启
    systemctl restart realm.service
    log "批量添加 ${#valid_rules[@]} 条规则"
    echo -e "${GREEN}✔ 成功添加 ${#valid_rules[@]} 条规则！${NC}"
}

delete_rule() {
    echo -e "\n${YELLOW}请选择删除方式：${NC}"
    echo "1) 单条删除"
    echo "2) 批量删除"
    read -rp "请输入选项 [1-2] (默认1): " del_mode
    del_mode=${del_mode:-1}

    case $del_mode in
        1) delete_single_rule ;;
        2) batch_delete_rules ;;
        *) echo -e "${RED}无效选项！${NC}" ;;
    esac
}

# 显示规则列表，并将 endpoints 行号数组存入 REPLY_LINES
# 返回 0 表示有规则，1 表示无规则
_list_rules_for_delete() {
    print_rules_header

    if [[ ! -f "$CONFIG_FILE" ]]; then
        echo -e "${YELLOW}配置文件不存在${NC}"
        return 1
    fi

    local IFS=$'\n'
    REPLY_LINES=($(grep -n '^\[\[endpoints\]\]' "$CONFIG_FILE" 2>/dev/null))

    if [ ${#REPLY_LINES[@]} -eq 0 ]; then
        echo "没有发现任何转发规则。"
        return 1
    fi

    local index=1
    for line in "${REPLY_LINES[@]}"; do
        local line_number=$(echo "$line" | cut -d ':' -f 1)
        local remark_line=$((line_number + 1))
        local listen_line=$((line_number + 2))
        local remote_line=$((line_number + 3))

        local remark=$(sed -n "${remark_line}p" "$CONFIG_FILE" | grep "^# 备注:" | cut -d ':' -f 2)
        local listen_info=$(sed -n "${listen_line}p" "$CONFIG_FILE" | cut -d '"' -f 2)
        local remote_info=$(sed -n "${remote_line}p" "$CONFIG_FILE" | cut -d '"' -f 2)

        printf "%-4s| %-24s| %-34s| %-20s\n" " $index" "$listen_info" "$remote_info" "$remark"
        echo -e "${BLUE}---------------------------------------------------------------------------------------------------------${NC}"
        ((index++))
    done
    return 0
}

# 计算某条规则在配置文件中的起止行号
_get_rule_line_range() {
    local idx=$1  # 0-based index in REPLY_LINES
    local chosen_line=${REPLY_LINES[$idx]}
    local start_line=$(echo "$chosen_line" | cut -d ':' -f 1)

    local next_endpoints_line=$(grep -n '^\[\[endpoints\]\]' "$CONFIG_FILE" | grep -A 1 "^$start_line:" | tail -n 1 | cut -d ':' -f 1)

    local end_line
    if [ -z "$next_endpoints_line" ] || [ "$next_endpoints_line" -le "$start_line" ]; then
        end_line=$(wc -l < "$CONFIG_FILE")
    else
        end_line=$((next_endpoints_line - 1))
    fi

    # 包含前面的空行
    while (( start_line > 1 )) && [[ "$(sed -n "$((start_line - 1))p" "$CONFIG_FILE")" =~ ^[[:space:]]*$ ]]; do
        ((start_line--))
    done

    echo "$start_line $end_line"
}

delete_single_rule() {
    local REPLY_LINES=()
    _list_rules_for_delete || return

    echo ""
    echo "请输入要删除的转发规则序号，直接按回车返回主菜单。"
    read -rp "选择: " choice
    if [ -z "$choice" ]; then
        echo "返回主菜单。"
        return
    fi

    if ! [[ $choice =~ ^[0-9]+$ ]]; then
        echo -e "${RED}无效输入，请输入数字。${NC}"
        return
    fi

    if [ "$choice" -lt 1 ] || [ "$choice" -gt ${#REPLY_LINES[@]} ]; then
        echo -e "${RED}选择超出范围，请输入有效序号。${NC}"
        return
    fi

    # 二次确认
    local chosen_line=${REPLY_LINES[$((choice-1))]}
    local start_line=$(echo "$chosen_line" | cut -d ':' -f 1)
    local listen_info=$(sed -n "$((start_line + 2))p" "$CONFIG_FILE" | cut -d '"' -f 2)
    local remote_info=$(sed -n "$((start_line + 3))p" "$CONFIG_FILE" | cut -d '"' -f 2)

    echo -e "${YELLOW}即将删除规则: ${listen_info} → ${remote_info}${NC}"
    read -rp "确认删除？(y/N): " confirm
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        echo "已取消删除。"
        return
    fi

    local range
    range=$(_get_rule_line_range $((choice - 1)))
    local s_line=${range% *}
    local e_line=${range#* }

    sed -i "${s_line},${e_line}d" "$CONFIG_FILE"
    sed -i '/^\s*$/d' "$CONFIG_FILE"

    log "删除规则: $listen_info → $remote_info"
    echo -e "${GREEN}✔ 转发规则已删除。${NC}"
    systemctl restart realm.service
}

batch_delete_rules() {
    local REPLY_LINES=()
    _list_rules_for_delete || return

    local total=${#REPLY_LINES[@]}
    echo ""
    echo -e "${CYAN}支持格式: 单个序号、逗号分隔、范围${NC}"
    echo -e "${CYAN}示例: 3  或  1,3,5  或  23-50  或  1,3,10-20${NC}"
    echo ""
    read -rp "请输入要删除的规则序号: " input
    [[ -z "$input" ]] && return

    # 解析输入为序号列表
    local -A idx_set=()
    local parse_error=false

    IFS=',' read -ra segments <<< "$input"
    for seg in "${segments[@]}"; do
        seg="${seg// /}"
        if [[ "$seg" =~ ^([0-9]+)-([0-9]+)$ ]]; then
            local range_start=${BASH_REMATCH[1]}
            local range_end=${BASH_REMATCH[2]}
            if (( range_start > range_end )); then
                local tmp=$range_start; range_start=$range_end; range_end=$tmp
            fi
            for (( n=range_start; n<=range_end; n++ )); do
                idx_set[$n]=1
            done
        elif [[ "$seg" =~ ^[0-9]+$ ]]; then
            idx_set[$seg]=1
        else
            echo -e "${RED}✖ 无效输入: ${seg}${NC}"
            parse_error=true
        fi
    done

    if $parse_error; then
        return
    fi

    # 排序并验证范围
    local sorted_indices=($(echo "${!idx_set[@]}" | tr ' ' '\n' | sort -n))

    if [[ ${#sorted_indices[@]} -eq 0 ]]; then
        echo -e "${YELLOW}未选择任何规则${NC}"
        return
    fi

    # 范围验证
    for idx in "${sorted_indices[@]}"; do
        if (( idx < 1 || idx > total )); then
            echo -e "${RED}✖ 序号 ${idx} 超出范围（共 ${total} 条规则）${NC}"
            return
        fi
    done

    # 预览
    echo -e "\n${YELLOW}即将删除以下 ${#sorted_indices[@]} 条规则：${NC}"
    echo -e "${BLUE}──────────────────────────────────────────────────────────${NC}"
    printf "${YELLOW}%-4s %-24s %-30s %s${NC}\n" "序号" "监听地址" "目标地址" "备注"
    echo -e "${BLUE}──────────────────────────────────────────────────────────${NC}"
    for idx in "${sorted_indices[@]}"; do
        local chosen_line=${REPLY_LINES[$((idx-1))]}
        local ln=$(echo "$chosen_line" | cut -d ':' -f 1)
        local listen_info=$(sed -n "$((ln + 2))p" "$CONFIG_FILE" | cut -d '"' -f 2)
        local remote_info=$(sed -n "$((ln + 3))p" "$CONFIG_FILE" | cut -d '"' -f 2)
        local remark=$(sed -n "$((ln + 1))p" "$CONFIG_FILE" | grep "^# 备注:" | cut -d ':' -f 2)
        printf "%-4s %-24s %-30s %s\n" " $idx" "$listen_info" "$remote_info" "$remark"
    done
    echo -e "${BLUE}──────────────────────────────────────────────────────────${NC}"

    read -rp "确认删除？(y/N): " confirm
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        echo "已取消删除。"
        return
    fi

    # 从后往前删除，避免行号偏移
    local reversed_indices=($(echo "${sorted_indices[@]}" | tr ' ' '\n' | sort -rn))
    local del_count=0

    for idx in "${reversed_indices[@]}"; do
        local range
        range=$(_get_rule_line_range $((idx - 1)))
        local s_line=${range% *}
        local e_line=${range#* }
        sed -i "${s_line},${e_line}d" "$CONFIG_FILE"
        ((del_count++))
    done

    sed -i '/^\s*$/d' "$CONFIG_FILE"
    systemctl restart realm.service
    log "批量删除 ${del_count} 条规则"
    echo -e "${GREEN}✔ 成功删除 ${del_count} 条规则！${NC}"
}

service_control() {
    case $1 in
        start)
            systemctl unmask realm.service
            systemctl daemon-reload
            systemctl restart realm.service
            systemctl enable realm.service
            log "启动服务"
            echo -e "${GREEN}✔ 服务已启动${NC}"
            ;;
        stop)
            systemctl stop realm
            log "停止服务"
            echo -e "${YELLOW}⚠ 服务已停止${NC}"
            ;;
        restart)
            systemctl unmask realm.service
            systemctl daemon-reload
            systemctl restart realm.service
            systemctl enable realm.service
            log "重启服务"
            echo -e "${GREEN}✔ 服务已重启${NC}"
            ;;
        status)
            if systemctl is-active --quiet realm; then
                echo -e "${GREEN}● 服务运行中${NC}"
            else
                echo -e "${RED}● 服务未运行${NC}"
            fi
            ;;
    esac
}

manage_cron() {
    echo -e "\n${YELLOW}定时任务管理：${NC}"
    echo "1. 添加每日重启任务"
    echo "2. 删除所有任务"
    echo "3. 查看当前任务"
    read -rp "请选择: " choice

    case $choice in
        1)
            read -rp "输入每日重启时间 (0-23): " hour
            if [[ "$hour" =~ ^[0-9]+$ ]] && (( hour >= 0 && hour <= 23 )); then
                echo "0 $hour * * * root /usr/bin/systemctl restart realm" >>/etc/crontab
                log "添加定时任务：每日 $hour 时重启"
                echo -e "${GREEN}✔ 定时任务已添加！${NC}"
            else
                echo -e "${RED}✖ 无效时间！${NC}"
            fi
            ;;
        2)
            sed -i "/realm/d" /etc/crontab
            log "清除定时任务"
            echo -e "${YELLOW}✔ 定时任务已清除！${NC}"
            ;;
        3)
            echo -e "\n${BLUE}当前定时任务：${NC}"
            cat /etc/crontab | grep --color=auto "realm"
            ;;
        *)
            echo -e "${RED}✖ 无效选择！${NC}"
            ;;
    esac
}

# ========================================
# 配置导入导出
# ========================================
# 导入后应用配置到 realm 服务
apply_imported_config() {
    # 检查 realm 是否已安装
    if [[ ! -x "$REALM_DIR/realm" || ! -f "$SERVICE_FILE" ]]; then
        echo -e "${YELLOW}⚠ Realm 尚未安装，请先通过菜单选项 [1] 安装 Realm${NC}"
        echo -e "${CYAN}  安装后配置将自动生效（已导入的配置文件会被保留）${NC}"
        return
    fi

    if systemctl is-active --quiet realm 2>/dev/null; then
        # 服务正在运行 → 需要重启才能加载新配置
        read -rp "是否立即重启服务使配置生效？(Y/n): " restart_choice
        restart_choice=${restart_choice:-Y}
        if [[ "$restart_choice" =~ ^[Yy]$ ]]; then
            systemctl daemon-reload
            systemctl restart realm.service
            # 等待并验证服务是否成功启动
            sleep 1
            if systemctl is-active --quiet realm 2>/dev/null; then
                echo -e "${GREEN}✔ 服务已重启，新配置已生效${NC}"
            else
                echo -e "${RED}✖ 服务重启后异常退出，配置可能存在错误${NC}"
                echo -e "${YELLOW}  请检查配置文件格式，或使用备份恢复：${NC}"
                echo -e "${CYAN}  ls ${CONFIG_FILE}.bak.*${NC}"
            fi
        else
            echo -e "${YELLOW}▶ 请稍后手动重启服务使配置生效${NC}"
        fi
    else
        # 服务未运行 → 需要启动
        read -rp "Realm 服务当前未运行，是否立即启动？(Y/n): " start_choice
        start_choice=${start_choice:-Y}
        if [[ "$start_choice" =~ ^[Yy]$ ]]; then
            systemctl unmask realm.service
            systemctl daemon-reload
            systemctl restart realm.service
            systemctl enable realm.service
            # 等待并验证服务是否成功启动
            sleep 1
            if systemctl is-active --quiet realm 2>/dev/null; then
                echo -e "${GREEN}✔ 服务已启动，配置已生效${NC}"
            else
                echo -e "${RED}✖ 服务启动后异常退出，配置可能存在错误${NC}"
                echo -e "${YELLOW}  请检查配置文件格式，或使用备份恢复：${NC}"
                echo -e "${CYAN}  ls ${CONFIG_FILE}.bak.*${NC}"
            fi
        else
            echo -e "${YELLOW}▶ 请稍后通过菜单选项 [5] 启动服务${NC}"
        fi
    fi
}

export_config() {
    if [[ ! -f "$CONFIG_FILE" ]]; then
        echo -e "${RED}✖ 配置文件不存在，请先安装 Realm 并添加规则${NC}"
        return
    fi

    echo -e "\n${YELLOW}配置导出方式：${NC}"
    echo "1. 导出到文件"
    echo "2. 导出为 Base64 字符串（方便跨服务器复制粘贴）"
    echo "0. 返回"
    echo -e ""
    read -rp "请选择: " choice

    case $choice in
        1)
            local default_path="/root/realm_config_backup.toml"
            echo -e ""
            echo -e "${BLUE}请输入导出文件路径（直接回车使用默认路径）${NC}"
            echo -e "${CYAN}默认路径: ${default_path}${NC}"
            echo -e ""
            read -rp "导出路径: " export_path
            export_path=${export_path:-$default_path}

            # 确保目标目录存在
            local export_dir
            export_dir=$(dirname "$export_path")
            if [[ ! -d "$export_dir" ]]; then
                echo -e "${RED}✖ 目录不存在: ${export_dir}${NC}"
                return
            fi

            if cp "$CONFIG_FILE" "$export_path"; then
                log "配置已导出到 $export_path"
                echo -e "${GREEN}✔ 配置已成功导出到: ${export_path}${NC}"
                echo -e ""
                echo -e "${CYAN}提示: 可使用 scp 将文件传输到其他服务器${NC}"
                echo -e "${CYAN}示例: scp ${export_path} root@目标IP:/root/${NC}"
            else
                echo -e "${RED}✖ 导出失败，请检查路径和权限${NC}"
            fi
            ;;
        2)
            echo -e ""
            echo -e "${BLUE}▶ 正在生成 Base64 编码...${NC}"
            echo -e ""
            echo -e "${YELLOW}═══════════ 配置内容（Base64）开始 ═══════════${NC}"
            base64 -w 0 "$CONFIG_FILE"
            echo ""
            echo -e "${YELLOW}═══════════ 配置内容（Base64）结束 ═══════════${NC}"
            echo -e ""
            echo -e "${CYAN}提示: 复制上面两行标记之间的内容，在目标服务器上使用「导入配置」功能粘贴即可${NC}"
            log "配置已导出为 Base64"
            ;;
        0|*)
            return
            ;;
    esac
}

import_config() {
    echo -e "\n${YELLOW}配置导入方式：${NC}"
    echo "1. 从文件导入"
    echo "2. 从 Base64 字符串导入（粘贴）"
    echo "0. 返回"
    echo -e ""
    read -rp "请选择: " choice

    case $choice in
        1)
            local default_path="/root/realm_config_backup.toml"
            echo -e ""
            echo -e "${BLUE}请输入配置文件路径（直接回车使用默认路径）${NC}"
            echo -e "${CYAN}默认路径: ${default_path}${NC}"
            echo -e ""
            read -rp "文件路径: " import_path
            import_path=${import_path:-$default_path}

            if [[ ! -f "$import_path" ]]; then
                echo -e "${RED}✖ 文件不存在: ${import_path}${NC}"
                return
            fi

            # 验证配置文件格式
            if ! grep -q '\[network\]' "$import_path"; then
                echo -e "${RED}✖ 无效的配置文件：缺少 [network] 段${NC}"
                return
            fi

            # 显示将要导入的规则
            echo -e ""
            echo -e "${BLUE}▶ 将要导入的配置内容：${NC}"
            echo -e "${CYAN}─────────────────────────────────────${NC}"
            cat "$import_path"
            echo -e "${CYAN}─────────────────────────────────────${NC}"

            local rule_count
            rule_count=$(grep -c '^\[\[endpoints\]\]' "$import_path" 2>/dev/null || echo "0")
            echo -e "${BLUE}包含 ${rule_count} 条转发规则${NC}"
            echo -e ""

            echo -e "${YELLOW}⚠ 导入将覆盖当前所有配置！${NC}"
            read -rp "确认导入？(y/N): " confirm
            if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
                echo "已取消导入。"
                return
            fi

            # 确保目录存在
            mkdir -p "$REALM_DIR"

            # 备份当前配置
            if [[ -f "$CONFIG_FILE" ]]; then
                local backup_path="${CONFIG_FILE}.bak.$(date '+%Y%m%d%H%M%S')"
                cp "$CONFIG_FILE" "$backup_path"
                echo -e "${GREEN}✓ 当前配置已备份到: ${backup_path}${NC}"
            fi

            # 导入配置
            if cp "$import_path" "$CONFIG_FILE"; then
                log "配置已从 $import_path 导入（${rule_count} 条规则）"
                echo -e "${GREEN}✔ 配置导入成功！${NC}"
                apply_imported_config
            else
                echo -e "${RED}✖ 导入失败，请检查权限${NC}"
            fi
            ;;
        2)
            echo -e ""
            echo -e "${BLUE}请粘贴 Base64 编码的配置内容（单行），然后按回车：${NC}"
            echo -e ""
            read -rp "Base64: " base64_input

            if [[ -z "$base64_input" ]]; then
                echo -e "${RED}✖ 未输入内容${NC}"
                return
            fi

            # 解码 Base64 直接到临时文件（避免 echo/变量导致内容损坏）
            local tmp_file
            tmp_file=$(mktemp /tmp/realm_import.XXXXXX)

            if ! printf '%s' "$base64_input" | base64 -d > "$tmp_file" 2>/dev/null; then
                echo -e "${RED}✖ Base64 解码失败，请检查输入内容是否完整${NC}"
                rm -f "$tmp_file"
                return
            fi

            # 检查解码结果是否为空
            if [[ ! -s "$tmp_file" ]]; then
                echo -e "${RED}✖ Base64 解码结果为空，请检查输入${NC}"
                rm -f "$tmp_file"
                return
            fi

            # 验证配置格式
            if ! grep -q '\[network\]' "$tmp_file"; then
                echo -e "${RED}✖ 无效的配置内容：缺少 [network] 段${NC}"
                rm -f "$tmp_file"
                return
            fi

            # 显示解码后的内容
            echo -e ""
            echo -e "${BLUE}▶ 解码后的配置内容：${NC}"
            echo -e "${CYAN}─────────────────────────────────────${NC}"
            cat "$tmp_file"
            echo -e "${CYAN}─────────────────────────────────────${NC}"

            local rule_count
            rule_count=$(grep -c '^\[\[endpoints\]\]' "$tmp_file" 2>/dev/null || echo "0")
            echo -e "${BLUE}包含 ${rule_count} 条转发规则${NC}"
            echo -e ""

            echo -e "${YELLOW}⚠ 导入将覆盖当前所有配置！${NC}"
            read -rp "确认导入？(y/N): " confirm
            if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
                echo "已取消导入。"
                rm -f "$tmp_file"
                return
            fi

            # 确保目录存在
            mkdir -p "$REALM_DIR"

            # 备份当前配置
            if [[ -f "$CONFIG_FILE" ]]; then
                local backup_path="${CONFIG_FILE}.bak.$(date '+%Y%m%d%H%M%S')"
                cp "$CONFIG_FILE" "$backup_path"
                echo -e "${GREEN}✓ 当前配置已备份到: ${backup_path}${NC}"
            fi

            # 写入配置（从临时文件复制，确保内容完整无损）
            if cp "$tmp_file" "$CONFIG_FILE"; then
                log "配置已从 Base64 导入（${rule_count} 条规则）"
                echo -e "${GREEN}✔ 配置导入成功！${NC}"
                apply_imported_config
            else
                echo -e "${RED}✖ 写入配置文件失败${NC}"
            fi
            rm -f "$tmp_file"
            ;;
        0|*)
            return
            ;;
    esac
}

# ========================================
# DNS 设置管理
# ========================================
manage_dns() {
    echo -e "\n${YELLOW}DNS 解析设置：${NC}"
    echo -e "${CYAN}用于转发规则中使用域名作为目标地址时的 DNS 解析配置${NC}"
    echo -e ""

    if [[ ! -f "$CONFIG_FILE" ]]; then
        echo -e "${RED}✖ 配置文件不存在，请先安装 Realm${NC}"
        return
    fi

    # 显示当前 DNS 配置
    if grep -q '^\[dns\]' "$CONFIG_FILE"; then
        echo -e "${GREEN}当前 DNS 配置：${NC}"
        echo -e "${CYAN}─────────────────────────────────────${NC}"
        sed -n '/^\[dns\]/,/^\[/p' "$CONFIG_FILE" | grep -v '^\[' | grep -v '^$' | while read -r line; do
            echo -e "  $line"
        done
        echo -e "${CYAN}─────────────────────────────────────${NC}"
    else
        echo -e "${YELLOW}当前未配置 DNS 设置（使用系统默认）${NC}"
    fi

    echo -e ""
    echo "1. 使用推荐配置（Google+Cloudflare IPv4/IPv6, TTL 300s）"
    echo "2. 仅 Cloudflare DNS（IPv4/IPv6）"
    echo "3. 自定义 DNS 配置"
    echo "4. 设置 DNS 缓存 TTL（影响域名 IP 更新频率）"
    echo "5. 删除 DNS 配置（使用系统默认）"
    echo "0. 返回主菜单"
    echo -e ""
    read -rp "请选择: " choice

    case $choice in
        1)
            # 删除已有 [dns] 段
            if grep -q '^\[dns\]' "$CONFIG_FILE"; then
                sed -i '/^\[dns\]/,/^\[/{/^\[dns\]/d;/^\[/!d}' "$CONFIG_FILE"
                sed -i '/^$/N;/^\n$/d' "$CONFIG_FILE"
            fi
            # 在 [network] 段后追加 DNS 配置
            sed -i '/^use_udp/a\\n[dns]\nmode = "ipv4_and_ipv6"\nprotocol = "tcp_and_udp"\nnameservers = ["8.8.8.8:53", "8.8.4.4:53", "1.1.1.1:53", "1.0.0.1:53", "[2001:4860:4860::8888]:53", "[2606:4700:4700::1111]:53"]\nmin_ttl = 0\nmax_ttl = 300\ncache_size = 256' "$CONFIG_FILE"
            echo -e "${GREEN}✔ 已应用推荐 DNS 配置（Google+Cloudflare IPv4/IPv6, TTL 300s）${NC}"
            echo -e "${CYAN}ℹ 域名解析结果将缓存最多 300 秒，适合动态 IP 场景${NC}"
            systemctl restart realm.service 2>/dev/null
            log "DNS 配置已更新: Google+Cloudflare IPv4/IPv6, max_ttl=300"
            ;;
        2)
            if grep -q '^\[dns\]' "$CONFIG_FILE"; then
                sed -i '/^\[dns\]/,/^\[/{/^\[dns\]/d;/^\[/!d}' "$CONFIG_FILE"
                sed -i '/^$/N;/^\n$/d' "$CONFIG_FILE"
            fi
            sed -i '/^use_udp/a\\n[dns]\nmode = "ipv4_and_ipv6"\nprotocol = "tcp_and_udp"\nnameservers = ["1.1.1.1:53", "1.0.0.1:53", "[2606:4700:4700::1111]:53", "[2606:4700:4700::1001]:53"]\nmin_ttl = 0\nmax_ttl = 300\ncache_size = 256' "$CONFIG_FILE"
            echo -e "${GREEN}✔ 已应用 Cloudflare DNS 配置（IPv4/IPv6, TTL 300s）${NC}"
            systemctl restart realm.service 2>/dev/null
            log "DNS 配置已更新: Cloudflare IPv4/IPv6, max_ttl=300"
            ;;
        3)
            echo -e "\n${BLUE}自定义 DNS 配置：${NC}"
            echo -e "${CYAN}IPv6 地址格式: [2001:4860:4860::8888]:53${NC}"
            read -rp "DNS 服务器1 IPv4 (默认 8.8.8.8:53): " dns1
            dns1=${dns1:-"8.8.8.8:53"}
            read -rp "DNS 服务器2 IPv4 (默认 1.1.1.1:53): " dns2
            dns2=${dns2:-"1.1.1.1:53"}
            read -rp "DNS 服务器3 IPv6 (默认 [2001:4860:4860::8888]:53, 留空跳过): " dns3
            dns3=${dns3:-"[2001:4860:4860::8888]:53"}
            read -rp "DNS 服务器4 IPv6 (默认 [2606:4700:4700::1111]:53, 留空跳过): " dns4
            dns4=${dns4:-"[2606:4700:4700::1111]:53"}
            read -rp "最大缓存 TTL 秒数 (默认 300, 动态IP建议 60-300): " max_ttl
            max_ttl=${max_ttl:-300}
            read -rp "最小缓存 TTL 秒数 (默认 0): " min_ttl
            min_ttl=${min_ttl:-0}

            if ! [[ "$max_ttl" =~ ^[0-9]+$ ]] || ! [[ "$min_ttl" =~ ^[0-9]+$ ]]; then
                echo -e "${RED}✖ TTL 必须为数字！${NC}"
                return
            fi

            # 构建 nameservers 列表
            local ns_list="\"$dns1\", \"$dns2\""
            if [[ -n "$dns3" ]]; then
                ns_list="$ns_list, \"$dns3\""
            fi
            if [[ -n "$dns4" ]]; then
                ns_list="$ns_list, \"$dns4\""
            fi

            if grep -q '^\[dns\]' "$CONFIG_FILE"; then
                sed -i '/^\[dns\]/,/^\[/{/^\[dns\]/d;/^\[/!d}' "$CONFIG_FILE"
                sed -i '/^$/N;/^\n$/d' "$CONFIG_FILE"
            fi
            sed -i "/^use_udp/a\\\\n[dns]\\nmode = \"ipv4_and_ipv6\"\\nprotocol = \"tcp_and_udp\"\\nnameservers = [$ns_list]\\nmin_ttl = $min_ttl\\nmax_ttl = $max_ttl\\ncache_size = 256" "$CONFIG_FILE"
            echo -e "${GREEN}✔ 自定义 DNS 配置已保存${NC}"
            systemctl restart realm.service 2>/dev/null
            log "DNS 配置已更新: 自定义 ($ns_list), max_ttl=$max_ttl"
            ;;
        4)
            echo -e "\n${BLUE}设置 DNS 缓存 TTL：${NC}"
            echo -e "${CYAN}TTL 值决定域名解析结果的缓存时间${NC}"
            echo -e "${CYAN}  - 动态 IP（每天更换）: 建议 60-300 秒${NC}"
            echo -e "${CYAN}  - 频繁变动 IP: 建议 10-60 秒${NC}"
            echo -e "${CYAN}  - 稳定 IP: 建议 600-3600 秒${NC}"
            echo -e ""
            read -rp "请输入最大 TTL 秒数 (当前域名IP每天更换建议 300): " new_ttl
            if ! [[ "$new_ttl" =~ ^[0-9]+$ ]]; then
                echo -e "${RED}✖ TTL 必须为数字！${NC}"
                return
            fi
            if grep -q '^\[dns\]' "$CONFIG_FILE"; then
                sed -i "s/^max_ttl = .*/max_ttl = $new_ttl/" "$CONFIG_FILE"
                echo -e "${GREEN}✔ DNS 缓存 TTL 已更新为 ${new_ttl} 秒${NC}"
                systemctl restart realm.service 2>/dev/null
                log "DNS TTL 已更新: max_ttl=$new_ttl"
            else
                echo -e "${YELLOW}⚠ 未找到 DNS 配置段，请先选择选项 1-3 创建 DNS 配置${NC}"
            fi
            ;;
        5)
            if grep -q '^\[dns\]' "$CONFIG_FILE"; then
                sed -i '/^\[dns\]/,/^\[/{/^\[dns\]/d;/^\[/!d}' "$CONFIG_FILE"
                sed -i '/^$/N;/^\n$/d' "$CONFIG_FILE"
                echo -e "${GREEN}✔ DNS 配置已删除，将使用系统默认 DNS${NC}"
                systemctl restart realm.service 2>/dev/null
                log "DNS 配置已删除"
            else
                echo -e "${YELLOW}当前没有自定义 DNS 配置${NC}"
            fi
            ;;
        0|*)
            return
            ;;
    esac
}

manage_config() {
    echo -e "\n${YELLOW}配置管理：${NC}"
    echo -e ""

    # 显示当前配置状态
    if [[ -f "$CONFIG_FILE" ]]; then
        local rule_count
        rule_count=$(grep -c '^\[\[endpoints\]\]' "$CONFIG_FILE" 2>/dev/null || echo "0")
        echo -e "当前配置: ${GREEN}${CONFIG_FILE}${NC} (${rule_count} 条规则)"
    else
        echo -e "当前配置: ${YELLOW}不存在${NC}"
    fi

    echo -e ""
    echo "1. 导出配置"
    echo "2. 导入配置"
    echo "0. 返回主菜单"
    echo -e ""
    read -rp "请选择: " choice

    case $choice in
        1) export_config ;;
        2) import_config ;;
        0|*) return ;;
    esac
}

# ========================================
# 日志查看
# ========================================
view_logs() {
    echo -e "\n${YELLOW}日志查看：${NC}"
    echo "1. 脚本管理日志（操作记录）"
    echo "2. Realm 服务日志（运行/错误日志）"
    echo "0. 返回"
    echo -e ""
    read -rp "请选择: " choice

    case $choice in
        1)
            echo -e "\n${BLUE}脚本管理日志（最近 20 条）：${NC}"
            echo -e "${CYAN}─────────────────────────────────────${NC}"
            if [[ -f "$LOG_FILE" ]]; then
                tail -n 20 "$LOG_FILE"
            else
                echo -e "${YELLOW}暂无日志记录${NC}"
            fi
            echo -e "${CYAN}─────────────────────────────────────${NC}"
            echo -e "${CYAN}完整日志: ${LOG_FILE}${NC}"
            ;;
        2)
            echo -e "\n${BLUE}Realm 服务日志（最近 50 条）：${NC}"
            echo -e "${CYAN}─────────────────────────────────────${NC}"
            if systemctl list-unit-files realm.service &>/dev/null; then
                journalctl -u realm.service -n 50 --no-pager
            else
                echo -e "${YELLOW}Realm 服务未安装，无日志可查${NC}"
            fi
            echo -e "${CYAN}─────────────────────────────────────${NC}"
            echo -e "${CYAN}查看更多: journalctl -u realm.service${NC}"
            ;;
        0|*)
            return
            ;;
    esac
}

# ========================================
# iptables 转发管理
# ========================================

# 检查 iptables 是否可用
check_iptables() {
    if ! command -v iptables &>/dev/null; then
        echo -e "${RED}✖ iptables 未安装，请先安装 iptables${NC}"
        echo -e "${CYAN}  Debian/Ubuntu: apt-get install -y iptables${NC}"
        echo -e "${CYAN}  CentOS/RHEL:   yum install -y iptables${NC}"
        return 1
    fi
    return 0
}

# 开启 IP 转发
enable_ip_forward() {
    echo 1 > /proc/sys/net/ipv4/ip_forward
    if grep -q "net.ipv4.ip_forward" /etc/sysctl.conf 2>/dev/null; then
        sed -i 's/^.*net\.ipv4\.ip_forward.*$/net.ipv4.ip_forward = 1/' /etc/sysctl.conf
    else
        echo "net.ipv4.ip_forward = 1" >> /etc/sysctl.conf
    fi
    sysctl -p /etc/sysctl.conf &>/dev/null
    if command -v ip6tables &>/dev/null; then
        echo 1 > /proc/sys/net/ipv6/conf/all/forwarding 2>/dev/null || true
    fi
}

# 初始化 iptables 自定义链
init_iptables_chains() {
    iptables -t nat -N "$IPTABLES_CHAIN" 2>/dev/null || true
    if ! iptables -t nat -C PREROUTING -j "$IPTABLES_CHAIN" 2>/dev/null; then
        iptables -t nat -I PREROUTING 1 -j "$IPTABLES_CHAIN"
    fi
    if ! iptables -t nat -C POSTROUTING -j MASQUERADE 2>/dev/null; then
        iptables -t nat -A POSTROUTING -j MASQUERADE
    fi
    if command -v ip6tables &>/dev/null; then
        ip6tables -t nat -N "$IPTABLES_CHAIN" 2>/dev/null || true
        if ! ip6tables -t nat -C PREROUTING -j "$IPTABLES_CHAIN" 2>/dev/null; then
            ip6tables -t nat -I PREROUTING 1 -j "$IPTABLES_CHAIN"
        fi
        if ! ip6tables -t nat -C POSTROUTING -j MASQUERADE 2>/dev/null; then
            ip6tables -t nat -A POSTROUTING -j MASQUERADE
        fi
    fi
}

# 解析域名为 IP
resolve_addr() {
    local addr="$1"
    local family="${2:-4}"  # 4=IPv4, 6=IPv6
    if is_domain_name "$addr"; then
        local ip
        if [[ "$family" == "6" ]]; then
            ip=$(getent hosts "$addr" 2>/dev/null | awk '{print $1}' | grep ':' | head -1)
        else
            ip=$(getent hosts "$addr" 2>/dev/null | awk '{print $1}' | grep -v ':' | head -1)
            if [[ -z "$ip" ]]; then
                ip=$(host "$addr" 2>/dev/null | awk '/has address/{print $4; exit}')
            fi
        fi
        echo "$ip"
    else
        echo "$addr"
    fi
}

# 写入（重置）iptables 规则文件头部说明
_write_iptables_rules_header() {
    mkdir -p "$IPTABLES_DIR"
    cat > "$IPTABLES_RULES_FILE" <<'EOF'
# iptables 转发规则配置文件
# 格式: 本地端口|协议|目标地址|目标端口|备注|监听模式
# 协议: tcp / udp / both
# 监听模式: 1=双栈(IPv4+IPv6) 2=仅IPv4 3=仅IPv6
EOF
}

# 初始化 iptables 目录和规则文件
init_iptables_dir() {
    mkdir -p "$IPTABLES_DIR"
    if [[ ! -f "$IPTABLES_RULES_FILE" ]]; then
        _write_iptables_rules_header
    fi
}

# 更新开机自启脚本并创建 systemd 服务
update_iptables_apply_script() {
    local apply_script="$IPTABLES_DIR/apply.sh"
    cat > "$apply_script" <<SCRIPT
#!/bin/bash
# Auto-generated by Realm-TCP-UDP-Forwarding-Panel
RULES_FILE="$IPTABLES_RULES_FILE"
CHAIN="$IPTABLES_CHAIN"

echo 1 > /proc/sys/net/ipv4/ip_forward

iptables -t nat -N "\$CHAIN" 2>/dev/null || true
iptables -t nat -C PREROUTING -j "\$CHAIN" 2>/dev/null || iptables -t nat -I PREROUTING 1 -j "\$CHAIN"
iptables -t nat -C POSTROUTING -j MASQUERADE 2>/dev/null || iptables -t nat -A POSTROUTING -j MASQUERADE
iptables -t nat -F "\$CHAIN"

if command -v ip6tables &>/dev/null; then
    echo 1 > /proc/sys/net/ipv6/conf/all/forwarding 2>/dev/null || true
    ip6tables -t nat -N "\$CHAIN" 2>/dev/null || true
    ip6tables -t nat -C PREROUTING -j "\$CHAIN" 2>/dev/null || ip6tables -t nat -I PREROUTING 1 -j "\$CHAIN"
    ip6tables -t nat -C POSTROUTING -j MASQUERADE 2>/dev/null || ip6tables -t nat -A POSTROUTING -j MASQUERADE
    ip6tables -t nat -F "\$CHAIN"
fi

[[ ! -f "\$RULES_FILE" ]] && exit 0

while IFS='|' read -r local_port protocol remote_addr remote_port remarks listen_mode; do
    [[ "\$local_port" =~ ^# ]] && continue
    [[ -z "\$local_port" ]] && continue

    target_ip="\$remote_addr"
    if echo "\$remote_addr" | grep -qE '^[a-zA-Z].*\.'; then
        target_ip=\$(getent hosts "\$remote_addr" 2>/dev/null | awk '{print \$1}' | grep -v ':' | head -1)
        [[ -z "\$target_ip" ]] && target_ip=\$(host "\$remote_addr" 2>/dev/null | awk '/has address/{print \$4; exit}')
        [[ -z "\$target_ip" ]] && continue
    fi

    if [[ "\$listen_mode" == "1" || "\$listen_mode" == "2" ]]; then
        [[ "\$protocol" == "tcp" || "\$protocol" == "both" ]] && \
            iptables -t nat -A "\$CHAIN" -p tcp --dport "\$local_port" -j DNAT --to-destination "\${target_ip}:\${remote_port}"
        [[ "\$protocol" == "udp" || "\$protocol" == "both" ]] && \
            iptables -t nat -A "\$CHAIN" -p udp --dport "\$local_port" -j DNAT --to-destination "\${target_ip}:\${remote_port}"
    fi

    if [[ ("\$listen_mode" == "1" || "\$listen_mode" == "3") ]] && command -v ip6tables &>/dev/null; then
        target_ip6=""
        if echo "\$remote_addr" | grep -q ':'; then
            target_ip6="\${remote_addr//[\[\]]/}"
        elif echo "\$remote_addr" | grep -qE '^[a-zA-Z].*\.'; then
            target_ip6=\$(getent hosts "\$remote_addr" 2>/dev/null | awk '{print \$1}' | grep ':' | head -1)
        fi
        if [[ -n "\$target_ip6" ]]; then
            [[ "\$protocol" == "tcp" || "\$protocol" == "both" ]] && \
                ip6tables -t nat -A "\$CHAIN" -p tcp --dport "\$local_port" -j DNAT --to-destination "[\${target_ip6}]:\${remote_port}"
            [[ "\$protocol" == "udp" || "\$protocol" == "both" ]] && \
                ip6tables -t nat -A "\$CHAIN" -p udp --dport "\$local_port" -j DNAT --to-destination "[\${target_ip6}]:\${remote_port}"
        fi
    fi
done < "\$RULES_FILE"
SCRIPT
    chmod +x "$apply_script"

    if [[ ! -f "$IPTABLES_SERVICE_FILE" ]]; then
        cat > "$IPTABLES_SERVICE_FILE" <<EOF
[Unit]
Description=iptables Port Forwarding Rules
After=network.target

[Service]
Type=oneshot
ExecStart=$IPTABLES_DIR/apply.sh
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
        systemctl daemon-reload
        systemctl enable iptables-forward.service 2>/dev/null
        log "iptables 转发服务已创建并启用开机自启"
    else
        systemctl daemon-reload
    fi
}

# 应用所有 iptables 规则
apply_all_iptables_rules() {
    enable_ip_forward
    init_iptables_chains

    iptables -t nat -F "$IPTABLES_CHAIN" 2>/dev/null
    if command -v ip6tables &>/dev/null; then
        ip6tables -t nat -F "$IPTABLES_CHAIN" 2>/dev/null
    fi

    [[ ! -f "$IPTABLES_RULES_FILE" ]] && { update_iptables_apply_script; return 0; }

    local applied=0
    while IFS='|' read -r local_port protocol remote_addr remote_port remarks listen_mode; do
        [[ "$local_port" =~ ^# ]] && continue
        [[ -z "$local_port" ]] && continue

        local target_ip
        target_ip=$(resolve_addr "$remote_addr" "4")
        if [[ -z "$target_ip" ]]; then
            echo -e "${YELLOW}⚠ 无法解析 $remote_addr，跳过规则 ${remarks:-:$local_port}${NC}"
            continue
        fi

        if [[ "$listen_mode" == "1" || "$listen_mode" == "2" ]]; then
            [[ "$protocol" == "tcp" || "$protocol" == "both" ]] && \
                iptables -t nat -A "$IPTABLES_CHAIN" -p tcp --dport "$local_port" -j DNAT --to-destination "${target_ip}:${remote_port}"
            [[ "$protocol" == "udp" || "$protocol" == "both" ]] && \
                iptables -t nat -A "$IPTABLES_CHAIN" -p udp --dport "$local_port" -j DNAT --to-destination "${target_ip}:${remote_port}"
            ((applied++))
        fi

        if [[ ("$listen_mode" == "1" || "$listen_mode" == "3") ]] && command -v ip6tables &>/dev/null; then
            local target_ip6=""
            if [[ "$remote_addr" =~ : ]]; then
                target_ip6="${remote_addr//[\[\]]/}"
            elif is_domain_name "$remote_addr"; then
                target_ip6=$(resolve_addr "$remote_addr" "6")
            fi
            if [[ -n "$target_ip6" ]]; then
                [[ "$protocol" == "tcp" || "$protocol" == "both" ]] && \
                    ip6tables -t nat -A "$IPTABLES_CHAIN" -p tcp --dport "$local_port" -j DNAT --to-destination "[${target_ip6}]:${remote_port}"
                [[ "$protocol" == "udp" || "$protocol" == "both" ]] && \
                    ip6tables -t nat -A "$IPTABLES_CHAIN" -p udp --dport "$local_port" -j DNAT --to-destination "[${target_ip6}]:${remote_port}"
            fi
        fi
    done < "$IPTABLES_RULES_FILE"

    update_iptables_apply_script
    return 0
}

# 显示规则表头
print_iptables_header() {
    echo -e "${CYAN}"
    printf "%-5s| %-22s| %-12s| %-38s| %-12s| %-20s\n" "序号" "  本地端口" "  协议" "  目标地址" "监听模式" "备注"
    echo -e "${NC}${BLUE}--------------------------------------------------------------------------------------------------------------------${NC}"
}

# 查看 iptables 转发规则
show_iptables_rules() {
    print_iptables_header

    if [[ ! -f "$IPTABLES_RULES_FILE" ]]; then
        echo -e "${YELLOW}规则文件不存在${NC}"
        return
    fi

    local index=1
    while IFS='|' read -r local_port protocol remote_addr remote_port remarks listen_mode; do
        [[ "$local_port" =~ ^# ]] && continue
        [[ -z "$local_port" ]] && continue

        local mode_str
        case "$listen_mode" in
            1) mode_str="双栈" ;;
            2) mode_str="仅IPv4" ;;
            3) mode_str="仅IPv6" ;;
            *) mode_str="双栈" ;;
        esac

        printf "%-4s| %-22s| %-12s| %-38s| %-12s| %-20s\n" \
            " $index" \
            " 0.0.0.0:${local_port}" \
            " ${protocol}" \
            " ${remote_addr}:${remote_port}" \
            " ${mode_str}" \
            "${remarks}"
        echo -e "${BLUE}--------------------------------------------------------------------------------------------------------------------${NC}"
        ((index++))
    done < "$IPTABLES_RULES_FILE"

    if [[ $index -eq 1 ]]; then
        echo -e "没有发现任何 iptables 转发规则。"
    fi
}

# 添加 iptables 转发规则（入口）
add_iptables_rule() {
    log "添加 iptables 转发规则"
    echo -e "\n${YELLOW}请选择添加方式：${NC}"
    echo "1) 单条添加"
    echo "2) 批量添加"
    read -rp "请输入选项 [1-2] (默认1): " add_mode
    add_mode=${add_mode:-1}

    case $add_mode in
        1) add_single_iptables_rule ;;
        2) batch_add_iptables_rules ;;
        *) echo -e "${RED}无效选项！${NC}" ;;
    esac
}

# 单条添加 iptables 规则
add_single_iptables_rule() {
    init_iptables_dir

    while : ; do
        echo -e "\n${BLUE}▶ 添加 iptables 转发规则（输入 q 退出）${NC}"

        read -rp "本地监听端口: " local_port
        [ "$local_port" = "q" ] && break
        read -rp "目标服务器地址(IP或域名): " remote_addr
        read -rp "目标端口: " remote_port
        read -rp "规则备注: " remark

        if ! [[ "$local_port" =~ ^[0-9]+$ ]] || ! [[ "$remote_port" =~ ^[0-9]+$ ]]; then
            echo -e "${RED}✖ 端口必须为数字！${NC}"
            continue
        fi
        if (( local_port < 1 || local_port > 65535 )); then
            echo -e "${RED}✖ 本地端口必须在 1-65535 范围内！${NC}"
            continue
        fi
        if (( remote_port < 1 || remote_port > 65535 )); then
            echo -e "${RED}✖ 目标端口必须在 1-65535 范围内！${NC}"
            continue
        fi

        if ! validate_remote_addr "$remote_addr"; then
            echo -e "${RED}✖ 无效的目标地址！请输入有效的IP或域名${NC}"
            continue
        fi

        # 协议选择
        echo -e "\n${YELLOW}请选择转发协议：${NC}"
        echo "1) TCP + UDP（默认）"
        echo "2) 仅 TCP"
        echo "3) 仅 UDP"
        read -rp "请输入选项 [1-3] (默认1): " proto_choice
        proto_choice=${proto_choice:-1}
        local protocol
        case $proto_choice in
            1) protocol="both" ;;
            2) protocol="tcp" ;;
            3) protocol="udp" ;;
            *) protocol="both" ;;
        esac

        # 监听模式选择
        echo -e "\n${YELLOW}请选择监听模式：${NC}"
        echo "1) 双栈 IPv4+IPv6（默认）"
        echo "2) 仅 IPv4"
        echo "3) 仅 IPv6"
        read -rp "请输入选项 [1-3] (默认1): " mode_choice
        mode_choice=${mode_choice:-1}
        if ! [[ "$mode_choice" =~ ^[123]$ ]]; then
            mode_choice=1
        fi

        if is_domain_name "$remote_addr"; then
            echo -e "${CYAN}ℹ 检测到域名，将在应用规则时进行 DNS 解析${NC}"
            echo -e "${YELLOW}⚠ 注意：iptables 不支持自动跟随域名 IP 变化，IP 变化后请手动重新应用规则${NC}"
        fi

        echo "${local_port}|${protocol}|${remote_addr}|${remote_port}|${remark}|${mode_choice}" >> "$IPTABLES_RULES_FILE"

        echo -e "${CYAN}正在应用规则...${NC}"
        apply_all_iptables_rules
        log "iptables 规则已添加: :${local_port} → ${remote_addr}:${remote_port} [${protocol}]"
        echo -e "${GREEN}✔ 添加成功！${NC}"

        read -rp "继续添加？(y/n): " cont
        [[ "$cont" != "y" ]] && break
    done
}

# 批量添加 iptables 规则
batch_add_iptables_rules() {
    init_iptables_dir

    echo -e "\n${BLUE}▶ 批量添加 iptables 转发规则${NC}"
    echo -e "${CYAN}格式: 本地端口,目标地址,目标端口[,备注][,协议][,监听模式]${NC}"
    echo -e "${CYAN}协议: 1=TCP+UDP(默认) 2=仅TCP 3=仅UDP${NC}"
    echo -e "${CYAN}监听模式: 1=双栈(默认) 2=仅IPv4 3=仅IPv6${NC}"
    echo -e "${CYAN}每行一条规则，输入空行结束${NC}"
    echo -e ""
    echo -e "${YELLOW}示例:${NC}"
    echo -e "  8080,1.2.3.4,80,网站转发"
    echo -e "  9090,example.com,443,域名转发,2,1"
    echo -e "  7070,10.0.0.1,22,SSH转发,1,2"
    echo -e ""

    local rules=()
    while true; do
        read -rp "> " line
        [[ -z "$line" ]] && break
        rules+=("$line")
    done

    if [[ ${#rules[@]} -eq 0 ]]; then
        echo -e "${YELLOW}未输入任何规则${NC}"
        return
    fi

    local valid_rules=()
    local error_count=0

    for i in "${!rules[@]}"; do
        local line="${rules[$i]}"
        local line_num=$((i + 1))

        IFS=',' read -ra parts <<< "$line"

        local lport="${parts[0]// /}"
        local raddr="${parts[1]// /}"
        local rport="${parts[2]// /}"
        local remark="${parts[3]// /}"
        local proto_num="${parts[4]// /}"
        local mode="${parts[5]// /}"
        proto_num=${proto_num:-1}
        mode=${mode:-1}

        if [[ -z "$lport" || -z "$raddr" || -z "$rport" ]]; then
            echo -e "${RED}✖ 第${line_num}行: 缺少必填字段（本地端口,目标地址,目标端口）${NC}"
            ((error_count++)); continue
        fi

        if ! [[ "$lport" =~ ^[0-9]+$ ]] || ! [[ "$rport" =~ ^[0-9]+$ ]]; then
            echo -e "${RED}✖ 第${line_num}行: 端口必须为数字${NC}"
            ((error_count++)); continue
        fi
        if (( lport < 1 || lport > 65535 )); then
            echo -e "${RED}✖ 第${line_num}行: 本地端口必须在 1-65535 范围内${NC}"
            ((error_count++)); continue
        fi
        if (( rport < 1 || rport > 65535 )); then
            echo -e "${RED}✖ 第${line_num}行: 目标端口必须在 1-65535 范围内${NC}"
            ((error_count++)); continue
        fi

        if ! validate_remote_addr "$raddr"; then
            echo -e "${RED}✖ 第${line_num}行: 无效的目标地址${NC}"
            ((error_count++)); continue
        fi

        local protocol
        case $proto_num in
            1) protocol="both" ;;
            2) protocol="tcp" ;;
            3) protocol="udp" ;;
            *) echo -e "${RED}✖ 第${line_num}行: 协议必须为 1/2/3${NC}"; ((error_count++)); continue ;;
        esac

        if ! [[ "$mode" =~ ^[123]$ ]]; then
            echo -e "${RED}✖ 第${line_num}行: 监听模式必须为 1/2/3${NC}"
            ((error_count++)); continue
        fi

        valid_rules+=("${lport}|${protocol}|${raddr}|${rport}|${remark}|${mode}")
    done

    if [[ ${#valid_rules[@]} -eq 0 ]]; then
        echo -e "${RED}✖ 没有有效的规则可添加${NC}"
        return
    fi

    if (( error_count > 0 )); then
        echo -e "\n${YELLOW}⚠ ${error_count} 条规则有误，${#valid_rules[@]} 条有效，是否继续？${NC}"
        read -rp "(y/n): " cont
        [[ "$cont" != "y" ]] && return
    fi

    echo -e "\n${YELLOW}将添加以下 ${#valid_rules[@]} 条规则：${NC}"
    echo -e "${BLUE}──────────────────────────────────────────────────────────────${NC}"
    printf "${YELLOW}%-4s %-8s %-12s %-30s %s${NC}\n" "序号" "端口" "协议" "目标地址" "备注"
    echo -e "${BLUE}──────────────────────────────────────────────────────────────${NC}"
    local idx=1
    for rule in "${valid_rules[@]}"; do
        IFS='|' read -ra p <<< "$rule"
        printf "%-4s %-8s %-12s %-30s %s\n" " $idx" "${p[0]}" "${p[1]}" "${p[2]}:${p[3]}" "${p[4]}"
        ((idx++))
    done
    echo -e "${BLUE}──────────────────────────────────────────────────────────────${NC}"

    read -rp "确认添加？(y/n): " confirm
    [[ "$confirm" != "y" ]] && return

    for rule in "${valid_rules[@]}"; do
        echo "$rule" >> "$IPTABLES_RULES_FILE"
    done

    echo -e "${CYAN}正在应用规则...${NC}"
    apply_all_iptables_rules
    log "iptables 批量添加 ${#valid_rules[@]} 条规则"
    echo -e "${GREEN}✔ 成功添加 ${#valid_rules[@]} 条规则！${NC}"
}

# 显示 iptables 规则列表（供删除操作使用）
_list_iptables_rules_for_delete() {
    print_iptables_header

    if [[ ! -f "$IPTABLES_RULES_FILE" ]]; then
        echo -e "${YELLOW}规则文件不存在${NC}"
        return 1
    fi

    IPTABLES_RULE_LINES=()
    local index=1

    while IFS='' read -r raw_line || [[ -n "$raw_line" ]]; do
        local trimmed="${raw_line// /}"
        [[ "$trimmed" =~ ^# ]] && continue
        [[ -z "$trimmed" ]] && continue

        IFS='|' read -ra parts <<< "$raw_line"
        local local_port="${parts[0]}"
        local protocol="${parts[1]}"
        local remote_addr="${parts[2]}"
        local remote_port="${parts[3]}"
        local remarks="${parts[4]}"
        local listen_mode="${parts[5]}"

        local mode_str
        case "$listen_mode" in
            1) mode_str="双栈" ;;
            2) mode_str="仅IPv4" ;;
            3) mode_str="仅IPv6" ;;
            *) mode_str="双栈" ;;
        esac

        printf "%-4s| %-22s| %-12s| %-38s| %-12s| %-20s\n" \
            " $index" \
            " 0.0.0.0:${local_port}" \
            " ${protocol}" \
            " ${remote_addr}:${remote_port}" \
            " ${mode_str}" \
            "${remarks}"
        echo -e "${BLUE}--------------------------------------------------------------------------------------------------------------------${NC}"

        IPTABLES_RULE_LINES+=("$raw_line")
        ((index++))
    done < "$IPTABLES_RULES_FILE"

    if [[ ${#IPTABLES_RULE_LINES[@]} -eq 0 ]]; then
        echo -e "没有发现任何 iptables 转发规则。"
        return 1
    fi
    return 0
}

# 删除 iptables 规则（入口）
delete_iptables_rule() {
    echo -e "\n${YELLOW}请选择删除方式：${NC}"
    echo "1) 单条删除"
    echo "2) 批量删除"
    read -rp "请输入选项 [1-2] (默认1): " del_mode
    del_mode=${del_mode:-1}

    case $del_mode in
        1) delete_single_iptables_rule ;;
        2) batch_delete_iptables_rules ;;
        *) echo -e "${RED}无效选项！${NC}" ;;
    esac
}

# 单条删除 iptables 规则
delete_single_iptables_rule() {
    local IPTABLES_RULE_LINES=()
    _list_iptables_rules_for_delete || return

    echo ""
    echo "请输入要删除的规则序号，直接按回车返回。"
    read -rp "选择: " choice
    if [[ -z "$choice" ]]; then
        echo "返回。"
        return
    fi

    if ! [[ $choice =~ ^[0-9]+$ ]]; then
        echo -e "${RED}无效输入，请输入数字。${NC}"
        return
    fi

    if (( choice < 1 || choice > ${#IPTABLES_RULE_LINES[@]} )); then
        echo -e "${RED}选择超出范围。${NC}"
        return
    fi

    local rule="${IPTABLES_RULE_LINES[$((choice-1))]}"
    IFS='|' read -ra parts <<< "$rule"
    echo -e "${YELLOW}即将删除规则: :${parts[0]} → ${parts[2]}:${parts[3]} [${parts[1]}]${NC}"
    read -rp "确认删除？(y/N): " confirm
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        echo "已取消。"
        return
    fi

    local escaped_rule
    escaped_rule=$(printf '%s\n' "$rule" | sed 's/[[\.*^$()+?{|]/\\&/g')
    sed -i "/^${escaped_rule}$/d" "$IPTABLES_RULES_FILE"

    echo -e "${CYAN}正在重新应用规则...${NC}"
    apply_all_iptables_rules
    log "iptables 删除规则: :${parts[0]} → ${parts[2]}:${parts[3]}"
    echo -e "${GREEN}✔ 规则已删除。${NC}"
}

# 批量删除 iptables 规则
batch_delete_iptables_rules() {
    local IPTABLES_RULE_LINES=()
    _list_iptables_rules_for_delete || return

    local total=${#IPTABLES_RULE_LINES[@]}
    echo ""
    echo -e "${CYAN}支持格式: 单个序号、逗号分隔、范围${NC}"
    echo -e "${CYAN}示例: 3  或  1,3,5  或  2-5  或  1,3,5-8${NC}"
    echo ""
    read -rp "请输入要删除的规则序号: " input
    [[ -z "$input" ]] && return

    local -A idx_set=()
    local parse_error=false

    IFS=',' read -ra segments <<< "$input"
    for seg in "${segments[@]}"; do
        seg="${seg// /}"
        if [[ "$seg" =~ ^([0-9]+)-([0-9]+)$ ]]; then
            local rs=${BASH_REMATCH[1]} re=${BASH_REMATCH[2]}
            (( rs > re )) && { local tmp=$rs; rs=$re; re=$tmp; }
            for (( n=rs; n<=re; n++ )); do idx_set[$n]=1; done
        elif [[ "$seg" =~ ^[0-9]+$ ]]; then
            idx_set[$seg]=1
        else
            echo -e "${RED}✖ 无效输入: ${seg}${NC}"
            parse_error=true
        fi
    done

    $parse_error && return

    local sorted_indices=($(echo "${!idx_set[@]}" | tr ' ' '\n' | sort -n))
    [[ ${#sorted_indices[@]} -eq 0 ]] && { echo -e "${YELLOW}未选择任何规则${NC}"; return; }

    for idx in "${sorted_indices[@]}"; do
        if (( idx < 1 || idx > total )); then
            echo -e "${RED}✖ 序号 ${idx} 超出范围（共 ${total} 条规则）${NC}"
            return
        fi
    done

    echo -e "\n${YELLOW}即将删除以下 ${#sorted_indices[@]} 条规则：${NC}"
    echo -e "${BLUE}──────────────────────────────────────────────────────────────${NC}"
    printf "${YELLOW}%-4s %-8s %-12s %-30s %s${NC}\n" "序号" "端口" "协议" "目标地址" "备注"
    echo -e "${BLUE}──────────────────────────────────────────────────────────────${NC}"
    for idx in "${sorted_indices[@]}"; do
        IFS='|' read -ra parts <<< "${IPTABLES_RULE_LINES[$((idx-1))]}"
        printf "%-4s %-8s %-12s %-30s %s\n" " $idx" "${parts[0]}" "${parts[1]}" "${parts[2]}:${parts[3]}" "${parts[4]}"
    done
    echo -e "${BLUE}──────────────────────────────────────────────────────────────${NC}"

    read -rp "确认删除？(y/N): " confirm
    [[ ! "$confirm" =~ ^[Yy]$ ]] && { echo "已取消。"; return; }

    local reversed_indices=($(echo "${sorted_indices[@]}" | tr ' ' '\n' | sort -rn))
    local del_count=0

    for idx in "${reversed_indices[@]}"; do
        local rule="${IPTABLES_RULE_LINES[$((idx-1))]}"
        local escaped_rule
        escaped_rule=$(printf '%s\n' "$rule" | sed 's/[[\.*^$()+?{|]/\\&/g')
        sed -i "/^${escaped_rule}$/d" "$IPTABLES_RULES_FILE"
        ((del_count++))
    done

    echo -e "${CYAN}正在重新应用规则...${NC}"
    apply_all_iptables_rules
    log "iptables 批量删除 ${del_count} 条规则"
    echo -e "${GREEN}✔ 成功删除 ${del_count} 条规则！${NC}"
}

# 清空所有 iptables 转发规则
flush_iptables_rules() {
    echo -e "${YELLOW}⚠ 将清空所有 iptables 转发规则！${NC}"
    read -rp "确认清空？(y/N): " confirm
    [[ ! "$confirm" =~ ^[Yy]$ ]] && { echo "已取消。"; return; }

    _write_iptables_rules_header

    iptables -t nat -F "$IPTABLES_CHAIN" 2>/dev/null
    if command -v ip6tables &>/dev/null; then
        ip6tables -t nat -F "$IPTABLES_CHAIN" 2>/dev/null
    fi

    update_iptables_apply_script
    log "iptables 转发规则已全部清空"
    echo -e "${GREEN}✔ 所有 iptables 转发规则已清空。${NC}"
}

# 查看当前 iptables NAT 规则
view_iptables_nat() {
    echo -e "\n${CYAN}=== 当前 iptables NAT 转发规则 ===${NC}"
    echo -e "${BLUE}--- IPv4 (iptables) ---${NC}"
    if iptables -t nat -L "$IPTABLES_CHAIN" -n --line-numbers 2>/dev/null; then
        :
    else
        echo "(链不存在或无规则)"
    fi

    if command -v ip6tables &>/dev/null; then
        echo -e "${BLUE}--- IPv6 (ip6tables) ---${NC}"
        ip6tables -t nat -L "$IPTABLES_CHAIN" -n --line-numbers 2>/dev/null || echo "(链不存在或无规则)"
    fi
}

# iptables 转发服务状态
iptables_service_status() {
    local svc_status enabled_status
    if systemctl is-active --quiet iptables-forward 2>/dev/null; then
        svc_status="${GREEN}已激活${NC}"
    else
        svc_status="${YELLOW}未激活${NC}"
    fi
    if systemctl is-enabled --quiet iptables-forward 2>/dev/null; then
        enabled_status="${GREEN}开机自启已启用${NC}"
    else
        enabled_status="${YELLOW}开机自启未启用${NC}"
    fi
    echo -e "  服务: $svc_status  |  $enabled_status"
}

# iptables 转发管理子菜单
iptables_menu() {
    check_iptables || return
    init_iptables_dir

    while true; do
        clear
        echo -e ""
        echo -e "${CYAN}    ┌─────────────────────────────────────────┐${NC}"
        echo -e "${CYAN}    │         iptables 转发管理               │${NC}"
        echo -e "${CYAN}    └─────────────────────────────────────────┘${NC}"
        echo -e ""
        iptables_service_status
        echo -e ""
        echo -e "${BLUE}    ┌──────────────────────────────────────────┐${NC}"
        echo -e "${BLUE}    │${NC}  ${GREEN}[1]${NC} 📋 查看转发规则                       ${BLUE}│${NC}"
        echo -e "${BLUE}    ├──────────────────────────────────────────┤${NC}"
        echo -e "${BLUE}    │${NC}  ${GREEN}[2]${NC} ➕ 添加转发规则（单条/批量）            ${BLUE}│${NC}"
        echo -e "${BLUE}    │${NC}  ${GREEN}[3]${NC} ➖ 删除转发规则（单条/批量）            ${BLUE}│${NC}"
        echo -e "${BLUE}    ├──────────────────────────────────────────┤${NC}"
        echo -e "${BLUE}    │${NC}  ${GREEN}[4]${NC} ↻  重新应用所有规则                    ${BLUE}│${NC}"
        echo -e "${BLUE}    │${NC}  ${GREEN}[5]${NC} 🔍 查看 iptables NAT 规则              ${BLUE}│${NC}"
        echo -e "${BLUE}    │${NC}  ${RED}[6]${NC} 🗑  清空所有转发规则                    ${BLUE}│${NC}"
        echo -e "${BLUE}    ├──────────────────────────────────────────┤${NC}"
        echo -e "${BLUE}    │${NC}  ${YELLOW}[7]${NC} 🔁 切换到 Realm 转发                   ${BLUE}│${NC}"
        echo -e "${BLUE}    ├──────────────────────────────────────────┤${NC}"
        echo -e "${BLUE}    │${NC}  ${CYAN}[0]${NC} ←  返回主菜单                          ${BLUE}│${NC}"
        echo -e "${BLUE}    └──────────────────────────────────────────┘${NC}"
        echo -e ""
        echo -ne "    ${CYAN}>>>${NC} 请输入选项: "
        read -r ichoice

        case $ichoice in
            1)
                show_iptables_rules
                read -rp "按回车键继续..."
                ;;
            2)
                add_iptables_rule
                read -rp "按回车键继续..."
                ;;
            3)
                delete_iptables_rule
                read -rp "按回车键继续..."
                ;;
            4)
                echo -e "${CYAN}正在应用所有规则...${NC}"
                apply_all_iptables_rules
                echo -e "${GREEN}✔ 规则已重新应用！${NC}"
                log "iptables 规则已重新应用"
                read -rp "按回车键继续..."
                ;;
            5)
                view_iptables_nat
                read -rp "按回车键继续..."
                ;;
            6)
                flush_iptables_rules
                read -rp "按回车键继续..."
                ;;
            7)
                switch_iptables_to_realm
                read -rp "按回车键继续..."
                ;;
            0) return ;;
            *) echo -e "${RED}无效选项！${NC}"; sleep 1 ;;
        esac
    done
}

# ========================================
# 转发方式切换（Realm ⇄ iptables）
# ========================================
# 统一中间格式（与 iptables 规则文件格式一致）：
#   本地端口|协议|目标地址|目标端口|备注|监听模式
#   协议: tcp / udp / both        监听模式: 1=双栈 2=仅IPv4 3=仅IPv6

# 拆分 "地址:端口" → SPLIT_HOST / SPLIT_PORT
_split_host_port() {
    local s="$1"
    SPLIT_HOST=""
    SPLIT_PORT=""
    if [[ "$s" =~ ^\[([^]]+)\]:([0-9]+)$ ]]; then
        SPLIT_HOST="${BASH_REMATCH[1]}"
        SPLIT_PORT="${BASH_REMATCH[2]}"
        return 0
    fi
    if [[ "$s" =~ ^([^:]+):([0-9]+)$ ]]; then
        SPLIT_HOST="${BASH_REMATCH[1]}"
        SPLIT_PORT="${BASH_REMATCH[2]}"
        return 0
    fi
    return 1
}

# 监听模式 → 描述（三个取值均占 4 个显示宽度，便于表格对齐）
_mode_desc() {
    case "$1" in
        2) echo "IPv4" ;;
        3) echo "IPv6" ;;
        *) echo "双栈" ;;
    esac
}

# 监听模式 + 端口 → Realm 监听地址
_mode_to_listen() {
    case "$1" in
        2) echo "0.0.0.0:$2" ;;
        *) echo "[::]:$2" ;;
    esac
}

# 目标地址 + 端口 → Realm remote 字符串（裸 IPv6 自动补方括号）
_join_remote() {
    local addr="$1"
    if [[ "$addr" == *:* && "$addr" != \[* ]]; then
        echo "[${addr}]:$2"
    else
        echo "${addr}:$2"
    fi
}

# 读取 Realm [network] 全局协议设置 → both / tcp / udp
_get_realm_global_protocol() {
    local no_tcp use_udp
    if [[ -f "$CONFIG_FILE" ]]; then
        no_tcp=$(grep -E '^[[:space:]]*no_tcp[[:space:]]*=' "$CONFIG_FILE" 2>/dev/null | head -1 | grep -oE 'true|false')
        use_udp=$(grep -E '^[[:space:]]*use_udp[[:space:]]*=' "$CONFIG_FILE" 2>/dev/null | head -1 | grep -oE 'true|false')
    fi
    no_tcp=${no_tcp:-false}
    use_udp=${use_udp:-true}

    if [[ "$no_tcp" == "true" && "$use_udp" == "true" ]]; then
        echo "udp"
    elif [[ "$no_tcp" == "false" && "$use_udp" == "false" ]]; then
        echo "tcp"
    else
        echo "both"
    fi
}

# 写入 Realm [network] 全局协议设置
_set_realm_global_protocol() {
    local proto="$1" no_tcp use_udp
    [[ -f "$CONFIG_FILE" ]] || return 1
    case "$proto" in
        tcp) no_tcp="false"; use_udp="false" ;;
        udp) no_tcp="true";  use_udp="true"  ;;
        *)   no_tcp="false"; use_udp="true"  ;;
    esac

    if grep -qE '^[[:space:]]*no_tcp[[:space:]]*=' "$CONFIG_FILE"; then
        sed -i -E "s|^[[:space:]]*no_tcp[[:space:]]*=.*|no_tcp = ${no_tcp}|" "$CONFIG_FILE"
    fi
    if grep -qE '^[[:space:]]*use_udp[[:space:]]*=' "$CONFIG_FILE"; then
        sed -i -E "s|^[[:space:]]*use_udp[[:space:]]*=.*|use_udp = ${use_udp}|" "$CONFIG_FILE"
    fi
    return 0
}

# 规则条数统计
_realm_rule_count() {
    [[ -f "$CONFIG_FILE" ]] || { echo 0; return; }
    local n
    n=$(grep -cE '^[[:space:]]*\[\[endpoints\]\]' "$CONFIG_FILE" 2>/dev/null)
    echo "${n:-0}"
}

_iptables_rule_count() {
    [[ -f "$IPTABLES_RULES_FILE" ]] || { echo 0; return; }
    local n
    n=$(grep -cE '^[^#[:space:]][^|]*\|' "$IPTABLES_RULES_FILE" 2>/dev/null)
    echo "${n:-0}"
}

# 当前内核中 IPT-FORWARD 链的条目数
_iptables_chain_count() {
    command -v iptables &>/dev/null || { echo 0; return; }
    local n
    n=$(iptables -t nat -S "$IPTABLES_CHAIN" 2>/dev/null | grep -c '^-A')
    echo "${n:-0}"
}

# 解析 Realm 规则 → SWITCH_RULES 数组（附带 SWITCH_WARNINGS 提示）
parse_realm_rules() {
    SWITCH_RULES=()
    SWITCH_WARNINGS=()

    [[ -f "$CONFIG_FILE" ]] || return 1

    local proto
    proto=$(_get_realm_global_protocol)

    # 使用非空白分隔符，避免 read 吞掉空备注造成的字段错位
    local remark listen remote lhost lport raddr rport mode
    while IFS=$'\037' read -r remark listen remote; do
        [[ -z "$listen" || -z "$remote" ]] && continue

        if ! _split_host_port "$listen"; then
            SWITCH_WARNINGS+=("跳过无法解析的监听地址: ${listen}")
            continue
        fi
        lhost="$SPLIT_HOST"
        lport="$SPLIT_PORT"

        case "$lhost" in
            "::"|"0:0:0:0:0:0:0:0")
                mode=1
                ;;
            "0.0.0.0"|"*")
                mode=2
                ;;
            *)
                if [[ "$lhost" == *:* ]]; then
                    mode=3
                    SWITCH_WARNINGS+=("${listen} 绑定了指定 IPv6 地址，转换后将监听全部 IPv6 地址")
                else
                    mode=2
                    SWITCH_WARNINGS+=("${listen} 绑定了指定 IPv4 地址，转换后将监听全部 IPv4 地址")
                fi
                ;;
        esac

        if ! _split_host_port "$remote"; then
            SWITCH_WARNINGS+=("跳过无法解析的目标地址: ${remote}")
            continue
        fi
        raddr="$SPLIT_HOST"
        rport="$SPLIT_PORT"

        # 备注中的分隔符会破坏 iptables 规则文件格式
        remark="${remark//|/ }"

        SWITCH_RULES+=("${lport}|${proto}|${raddr}|${rport}|${remark}|${mode}")
    done < <(awk '
        BEGIN { SEP = sprintf("%c", 31) }
        /^[[:space:]]*\[\[endpoints\]\]/ {
            if (found) print remark SEP listen SEP remote
            found = 1; remark = ""; listen = ""; remote = ""
            next
        }
        /^[[:space:]]*\[/ {
            if (found) { print remark SEP listen SEP remote; found = 0 }
            next
        }
        found == 0 { next }
        /^[[:space:]]*#/ {
            if (index($0, "备注") > 0) {
                line = $0
                sub(/^[^:]*:[[:space:]]*/, "", line)
                remark = line
            }
            next
        }
        /^[[:space:]]*listen[[:space:]]*=/ {
            if (match($0, /"[^"]*"/)) listen = substr($0, RSTART + 1, RLENGTH - 2)
            next
        }
        /^[[:space:]]*remote[[:space:]]*=/ {
            if (match($0, /"[^"]*"/)) remote = substr($0, RSTART + 1, RLENGTH - 2)
            next
        }
        END { if (found) print remark SEP listen SEP remote }
    ' "$CONFIG_FILE")

    return 0
}

# 解析 iptables 规则 → SWITCH_RULES 数组
parse_iptables_rules() {
    SWITCH_RULES=()
    SWITCH_WARNINGS=()

    [[ -f "$IPTABLES_RULES_FILE" ]] || return 1

    local lport proto raddr rport remark mode
    while IFS='|' read -r lport proto raddr rport remark mode; do
        [[ "$lport" =~ ^[[:space:]]*# ]] && continue
        [[ -z "${lport// /}" ]] && continue
        [[ -z "$raddr" || -z "$rport" ]] && continue

        lport="${lport// /}"
        proto="${proto:-both}"
        mode="${mode:-1}"
        [[ "$mode" =~ ^[123]$ ]] || mode=1

        SWITCH_RULES+=("${lport}|${proto}|${raddr}|${rport}|${remark}|${mode}")
    done < "$IPTABLES_RULES_FILE"

    return 0
}

# 迁移预览表（$1 = 目标方式 realm / iptables）
_preview_switch_rules() {
    local target="$1"
    local title_after
    if [[ "$target" == "realm" ]]; then
        title_after="转换后(Realm 监听)"
    else
        title_after="转换后(iptables)"
    fi

    echo -e "${BLUE}────────────────────────────────────────────────────────────────────────────────${NC}"
    # 监听模式列的取值显示宽度一致，直接跟两个空格，避免中英文混排错位
    printf "${YELLOW}%-4s %-24s %-6s %s  %-26s %s${NC}\n" "序号" "$title_after" "协议" "监听" "目标地址" "备注"
    echo -e "${BLUE}────────────────────────────────────────────────────────────────────────────────${NC}"

    local idx=1 rule lp proto raddr rport remark mode listen_str
    for rule in "${SWITCH_RULES[@]}"; do
        IFS='|' read -r lp proto raddr rport remark mode <<< "$rule"
        if [[ "$target" == "realm" ]]; then
            listen_str=$(_mode_to_listen "$mode" "$lp")
        else
            listen_str="DNAT :${lp}"
        fi
        printf "%-4s %-24s %-6s %s  %-26s %s\n" \
            "$idx" "$listen_str" "$proto" "$(_mode_desc "$mode")" "$(_join_remote "$raddr" "$rport")" "$remark"
        ((idx++))
    done
    echo -e "${BLUE}────────────────────────────────────────────────────────────────────────────────${NC}"
}

# 清空 Realm 配置中的所有 [[endpoints]] 段（保留 [network] / [dns] 等）
_clear_realm_endpoints() {
    [[ -f "$CONFIG_FILE" ]] || return 1
    local tmp="${CONFIG_FILE}.switch.tmp"

    awk '
        /^[[:space:]]*\[\[endpoints\]\]/ { skip = 1; next }
        /^[[:space:]]*\[endpoints\./     { if (skip) next }
        /^[[:space:]]*\[/                { skip = 0 }
        skip { next }
        { print }
    ' "$CONFIG_FILE" > "$tmp" || { rm -f "$tmp"; return 1; }

    # 去掉结尾多余空行
    awk 'BEGIN{blank=0} {if ($0 ~ /^[[:space:]]*$/) {blank++} else {while (blank>0){print ""; blank--}; print}}' \
        "$tmp" > "${tmp}.2" && mv "${tmp}.2" "$tmp"

    mv "$tmp" "$CONFIG_FILE"
    return 0
}

# 若 Realm 配置文件不存在则创建默认骨架
_ensure_realm_config() {
    [[ -f "$CONFIG_FILE" ]] && return 0
    mkdir -p "$REALM_DIR"
    cat > "$CONFIG_FILE" <<'INITEOF'
[network]
no_tcp = false
use_udp = true

[dns]
mode = "ipv4_and_ipv6"
protocol = "tcp_and_udp"
nameservers = ["8.8.8.8:53", "8.8.4.4:53", "1.1.1.1:53", "1.0.0.1:53", "[2001:4860:4860::8888]:53", "[2606:4700:4700::1111]:53"]
min_ttl = 0
max_ttl = 300
cache_size = 256
INITEOF
    return 0
}

# 切换前备份（$1 = 方向标识）→ 输出备份目录路径
_create_switch_backup() {
    local direction="$1"
    local ts dir
    ts=$(date '+%Y%m%d-%H%M%S')
    dir="${SWITCH_BACKUP_DIR}/${ts}-${direction}"

    mkdir -p "$dir" 2>/dev/null || return 1
    [[ -f "$CONFIG_FILE" ]] && cp "$CONFIG_FILE" "$dir/config.toml" 2>/dev/null
    [[ -f "$IPTABLES_RULES_FILE" ]] && cp "$IPTABLES_RULES_FILE" "$dir/rules.conf" 2>/dev/null

    {
        echo "direction=${direction}"
        echo "time=$(date '+%Y-%m-%d %H:%M:%S')"
        echo "realm_rules=$(_realm_rule_count)"
        echo "iptables_rules=$(_iptables_rule_count)"
        echo "iptables_chain=$(_iptables_chain_count)"
        echo "realm_active=$(systemctl is-active realm 2>/dev/null || true)"
        echo "realm_enabled=$(systemctl is-enabled realm 2>/dev/null || true)"
        echo "iptables_enabled=$(systemctl is-enabled iptables-forward 2>/dev/null || true)"
    } > "$dir/meta.conf" 2>/dev/null

    # 只保留最近 10 份备份
    local old
    while read -r old; do
        [[ -n "$old" ]] && rm -rf "$old"
    done < <(ls -1dt "${SWITCH_BACKUP_DIR}"/*/ 2>/dev/null | tail -n +11)

    echo "$dir"
    return 0
}

# 读取备份元信息 _meta_get <文件> <键>
_meta_get() {
    [[ -f "$1" ]] || return 1
    grep -E "^$2=" "$1" 2>/dev/null | head -1 | cut -d'=' -f2-
}

# 停止 Realm 服务
_stop_realm_service() {
    systemctl stop realm 2>/dev/null
    systemctl disable realm 2>/dev/null
}

# 停止 iptables 转发（清空内核规则 + 停用开机自启）
_stop_iptables_forward() {
    iptables -t nat -F "$IPTABLES_CHAIN" 2>/dev/null
    if command -v ip6tables &>/dev/null; then
        ip6tables -t nat -F "$IPTABLES_CHAIN" 2>/dev/null
    fi
    systemctl stop iptables-forward 2>/dev/null
    systemctl disable iptables-forward 2>/dev/null
}

# ----------------------------------------
# Realm ➜ iptables
# ----------------------------------------
switch_realm_to_iptables() {
    echo -e "\n${CYAN}══════════ Realm ➜ iptables 规则迁移 ══════════${NC}"

    check_iptables || return

    if [[ ! -f "$CONFIG_FILE" ]]; then
        echo -e "${RED}✖ 未找到 Realm 配置文件: ${CONFIG_FILE}${NC}"
        return
    fi

    parse_realm_rules
    if [[ ${#SWITCH_RULES[@]} -eq 0 ]]; then
        echo -e "${YELLOW}⚠ Realm 配置中没有可迁移的转发规则${NC}"
        return
    fi

    local global_proto
    global_proto=$(_get_realm_global_protocol)

    echo -e "\n${YELLOW}将把以下 ${#SWITCH_RULES[@]} 条 Realm 规则转换为 iptables 转发：${NC}"
    _preview_switch_rules iptables

    echo -e "\n${CYAN}转换说明：${NC}"
    echo -e "  • 协议取自 Realm ${CYAN}[network]${NC} 全局设置，当前为 ${GREEN}${global_proto}${NC}"
    echo -e "  • iptables 走内核 NAT，切换后本机不再监听端口（${CYAN}ss -tlnp${NC} 看不到）"
    echo -e "  • 目标为域名时，iptables 仅在应用规则时解析一次，域名 IP 变化后需重新应用"
    local w
    for w in "${SWITCH_WARNINGS[@]}"; do
        echo -e "  ${YELLOW}⚠ ${w}${NC}"
    done

    # ---- 目标侧写入方式 ----
    init_iptables_dir
    local -A exist_ports=()
    local existing_count
    existing_count=$(_iptables_rule_count)

    local write_mode=1
    if (( existing_count > 0 )); then
        local p
        while IFS='|' read -r p _; do
            [[ "$p" =~ ^[[:space:]]*# ]] && continue
            [[ -z "${p// /}" ]] && continue
            exist_ports["${p// /}"]=1
        done < "$IPTABLES_RULES_FILE"

        echo -e "\n${YELLOW}iptables 侧已存在 ${existing_count} 条规则，如何写入？${NC}"
        echo "1) 覆盖：清空 iptables 现有规则后写入"
        echo "2) 合并：保留现有规则，本地端口冲突的跳过（默认）"
        read -rp "请输入选项 [1-2] (默认2): " write_mode
        write_mode=${write_mode:-2}
        if ! [[ "$write_mode" =~ ^[12]$ ]]; then
            echo -e "${RED}✖ 无效选项，已取消${NC}"
            return
        fi
    fi

    # ---- 源侧处理方式 ----
    echo -e "\n${YELLOW}迁移完成后如何处理 Realm（源方式）？${NC}"
    echo "1) 停止并禁用 Realm 服务，同时清空 Realm 规则（彻底切换）"
    echo "2) 停止并禁用 Realm 服务，保留 Realm 规则（默认，可随时切回）"
    echo "3) 保持 Realm 运行（不推荐：端口重叠时 iptables DNAT 优先，Realm 收不到流量）"
    read -rp "请输入选项 [1-3] (默认2): " src_action
    src_action=${src_action:-2}
    if ! [[ "$src_action" =~ ^[123]$ ]]; then
        echo -e "${RED}✖ 无效选项，已取消${NC}"
        return
    fi

    echo -e ""
    read -rp "确认开始迁移？(y/N): " confirm
    [[ ! "$confirm" =~ ^[Yy]$ ]] && { echo "已取消。"; return; }

    # ---- 执行 ----
    local backup_dir
    backup_dir=$(_create_switch_backup "realm2iptables")
    if [[ -n "$backup_dir" ]]; then
        echo -e "${GREEN}✓ 已备份切换前状态: ${backup_dir}${NC}"
    else
        echo -e "${YELLOW}⚠ 备份创建失败，将继续迁移${NC}"
    fi

    if [[ "$write_mode" == "1" ]]; then
        _write_iptables_rules_header
    fi

    local added=0 skipped=0 rule lp
    for rule in "${SWITCH_RULES[@]}"; do
        IFS='|' read -r lp _ <<< "$rule"
        if [[ "$write_mode" == "2" && -n "${exist_ports[$lp]}" ]]; then
            echo -e "${YELLOW}  ↷ 端口 ${lp} 在 iptables 侧已存在，跳过${NC}"
            ((skipped++))
            continue
        fi
        echo "$rule" >> "$IPTABLES_RULES_FILE"
        ((added++))
    done

    echo -e "${CYAN}正在应用 iptables 规则...${NC}"
    apply_all_iptables_rules
    systemctl enable iptables-forward &>/dev/null
    systemctl start iptables-forward &>/dev/null

    case "$src_action" in
        1)
            _stop_realm_service
            _clear_realm_endpoints
            echo -e "${GREEN}✓ Realm 服务已停止并禁用，Realm 规则已清空${NC}"
            ;;
        2)
            _stop_realm_service
            echo -e "${GREEN}✓ Realm 服务已停止并禁用，配置文件保留（可随时切回）${NC}"
            ;;
        3)
            echo -e "${YELLOW}⚠ Realm 仍在运行，端口重叠时流量将被 iptables DNAT 优先接管${NC}"
            ;;
    esac

    log "转发方式切换: Realm → iptables，写入 ${added} 条，跳过 ${skipped} 条"
    echo -e "\n${GREEN}✔ 迁移完成：写入 ${added} 条规则${NC}"
    (( skipped > 0 )) && echo -e "${YELLOW}  跳过 ${skipped} 条（端口冲突）${NC}"
    echo -e "${CYAN}  当前生效的 NAT 条目: $(_iptables_chain_count) 条${NC}"
}

# ----------------------------------------
# iptables ➜ Realm
# ----------------------------------------
switch_iptables_to_realm() {
    echo -e "\n${CYAN}══════════ iptables ➜ Realm 规则迁移 ══════════${NC}"

    if [[ ! -f "$IPTABLES_RULES_FILE" ]]; then
        echo -e "${RED}✖ 未找到 iptables 规则文件: ${IPTABLES_RULES_FILE}${NC}"
        return
    fi

    parse_iptables_rules
    if [[ ${#SWITCH_RULES[@]} -eq 0 ]]; then
        echo -e "${YELLOW}⚠ iptables 规则文件中没有可迁移的转发规则${NC}"
        return
    fi

    echo -e "\n${YELLOW}将把以下 ${#SWITCH_RULES[@]} 条 iptables 规则转换为 Realm 转发：${NC}"
    _preview_switch_rules realm

    # 协议一致性分析（Realm 的协议开关是全局的）+ 仅IPv6 规则统计
    local rule lp proto raddr rport remark mode
    local -A proto_set=()
    local v6only_count=0
    for rule in "${SWITCH_RULES[@]}"; do
        IFS='|' read -r lp proto raddr rport remark mode <<< "$rule"
        proto_set["$proto"]=1
        [[ "$mode" == "3" ]] && ((v6only_count++))
    done

    local uniq_proto=""
    if [[ ${#proto_set[@]} -eq 1 ]]; then
        uniq_proto="${!proto_set[@]}"
    fi

    echo -e "\n${CYAN}转换说明：${NC}"
    echo -e "  • Realm 走用户态转发，切换后本机会真实监听这些端口"
    echo -e "  • 目标为域名时 Realm 会自动跟随 DNS 变化，无需重新应用"
    echo -e "  • ${YELLOW}Realm 的 TCP/UDP 开关是全局的（[network] 段），不能逐条设置${NC}"

    local target_proto="both"
    if [[ -n "$uniq_proto" && "$uniq_proto" != "both" ]]; then
        echo -e "  • 全部规则协议一致（${GREEN}${uniq_proto}${NC}），可同步写入 Realm 全局协议设置"
        read -rp "是否将 Realm 全局协议设为 ${uniq_proto}？(Y/n): " set_proto
        set_proto=${set_proto:-Y}
        [[ "$set_proto" =~ ^[Yy]$ ]] && target_proto="$uniq_proto"
    elif [[ -z "$uniq_proto" ]]; then
        echo -e "  ${YELLOW}⚠ 规则中混用了不同协议，转换后统一按 TCP+UDP 处理${NC}"
    fi

    if (( v6only_count > 0 )); then
        echo -e "  ${YELLOW}⚠ 有 ${v6only_count} 条「仅IPv6」规则：Realm 以 [::] 双栈方式监听，切回 iptables 时会变成双栈${NC}"
    fi

    local w
    for w in "${SWITCH_WARNINGS[@]}"; do
        echo -e "  ${YELLOW}⚠ ${w}${NC}"
    done

    if [[ ! -x "$REALM_DIR/realm" || ! -f "$SERVICE_FILE" ]]; then
        echo -e "  ${YELLOW}⚠ Realm 尚未安装，规则会写入配置文件，但需先通过主菜单 [1] 安装才能生效${NC}"
    fi

    # ---- 目标侧写入方式 ----
    _ensure_realm_config
    local -A exist_ports=()
    local existing_count
    existing_count=$(_realm_rule_count)

    local write_mode=1
    if (( existing_count > 0 )); then
        local old_rules=() r
        parse_realm_rules
        old_rules=("${SWITCH_RULES[@]}")
        for r in "${old_rules[@]}"; do
            IFS='|' read -r lp _ <<< "$r"
            exist_ports["$lp"]=1
        done
        # 恢复待迁移规则集
        parse_iptables_rules

        echo -e "\n${YELLOW}Realm 侧已存在 ${existing_count} 条规则，如何写入？${NC}"
        echo "1) 覆盖：清空 Realm 现有规则后写入"
        echo "2) 合并：保留现有规则，本地端口冲突的跳过（默认）"
        read -rp "请输入选项 [1-2] (默认2): " write_mode
        write_mode=${write_mode:-2}
        if ! [[ "$write_mode" =~ ^[12]$ ]]; then
            echo -e "${RED}✖ 无效选项，已取消${NC}"
            return
        fi
    fi

    # ---- 源侧处理方式 ----
    echo -e "\n${YELLOW}迁移完成后如何处理 iptables（源方式）？${NC}"
    echo "1) 清空内核 NAT 规则并停用开机自启，同时清空 iptables 规则文件（彻底切换）"
    echo "2) 清空内核 NAT 规则并停用开机自启，保留规则文件（默认，可随时切回）"
    echo "3) 保留 iptables 规则（不推荐：DNAT 优先级高于 Realm 监听，Realm 收不到流量）"
    read -rp "请输入选项 [1-3] (默认2): " src_action
    src_action=${src_action:-2}
    if ! [[ "$src_action" =~ ^[123]$ ]]; then
        echo -e "${RED}✖ 无效选项，已取消${NC}"
        return
    fi

    echo -e ""
    read -rp "确认开始迁移？(y/N): " confirm
    [[ ! "$confirm" =~ ^[Yy]$ ]] && { echo "已取消。"; return; }

    # ---- 执行 ----
    local backup_dir
    backup_dir=$(_create_switch_backup "iptables2realm")
    if [[ -n "$backup_dir" ]]; then
        echo -e "${GREEN}✓ 已备份切换前状态: ${backup_dir}${NC}"
    else
        echo -e "${YELLOW}⚠ 备份创建失败，将继续迁移${NC}"
    fi

    if [[ "$write_mode" == "1" ]]; then
        _clear_realm_endpoints
    fi

    _set_realm_global_protocol "$target_proto"

    local added=0 skipped=0 listen_addr remote_full
    for rule in "${SWITCH_RULES[@]}"; do
        IFS='|' read -r lp proto raddr rport remark mode <<< "$rule"
        if [[ "$write_mode" == "2" && -n "${exist_ports[$lp]}" ]]; then
            echo -e "${YELLOW}  ↷ 端口 ${lp} 在 Realm 侧已存在，跳过${NC}"
            ((skipped++))
            continue
        fi

        listen_addr=$(_mode_to_listen "$mode" "$lp")
        remote_full=$(_join_remote "$raddr" "$rport")

        cat >> "$CONFIG_FILE" <<EOF

[[endpoints]]
# 备注: ${remark}
listen = "${listen_addr}"
remote = "${remote_full}"
EOF
        ((added++))
    done

    # ---- 启动 Realm ----
    local realm_ok=false
    if [[ -x "$REALM_DIR/realm" && -f "$SERVICE_FILE" ]]; then
        echo -e "${CYAN}正在启动 Realm 服务...${NC}"
        systemctl unmask realm.service &>/dev/null
        systemctl daemon-reload
        systemctl restart realm.service
        systemctl enable realm.service &>/dev/null
        sleep 1
        if systemctl is-active --quiet realm 2>/dev/null; then
            realm_ok=true
            echo -e "${GREEN}✓ Realm 服务已启动${NC}"
        else
            echo -e "${RED}✖ Realm 服务启动失败，配置可能存在问题${NC}"
            echo -e "${CYAN}  排查: journalctl -u realm -n 30 --no-pager${NC}"
        fi
    else
        echo -e "${YELLOW}⚠ Realm 未安装，规则已写入配置文件，安装后即可生效${NC}"
    fi

    # Realm 未能接管时保留 iptables，避免转发中断
    if ! $realm_ok && [[ "$src_action" != "3" ]]; then
        echo -e "${YELLOW}⚠ Realm 未成功接管转发，已自动保留 iptables 规则以免中断${NC}"
        echo -e "${CYAN}  Realm 正常后可回到本菜单再次执行切换，或使用备份回滚${NC}"
        src_action=3
    fi

    case "$src_action" in
        1)
            _stop_iptables_forward
            _write_iptables_rules_header
            update_iptables_apply_script
            echo -e "${GREEN}✓ iptables 转发已停用，规则文件已清空${NC}"
            ;;
        2)
            _stop_iptables_forward
            echo -e "${GREEN}✓ iptables 转发已停用，规则文件保留（可随时切回）${NC}"
            ;;
        3)
            echo -e "${YELLOW}⚠ iptables 规则仍然生效${NC}"
            ;;
    esac

    log "转发方式切换: iptables → Realm，写入 ${added} 条，跳过 ${skipped} 条"
    echo -e "\n${GREEN}✔ 迁移完成：写入 ${added} 条规则${NC}"
    (( skipped > 0 )) && echo -e "${YELLOW}  跳过 ${skipped} 条（端口冲突）${NC}"
}

# ----------------------------------------
# 规则对照 / 冲突检查
# ----------------------------------------
show_forward_comparison() {
    echo -e "\n${CYAN}══════════ 两种转发方式规则对照 ══════════${NC}"

    local -A realm_ports=()
    local -A ipt_ports=()
    local rule lp

    parse_realm_rules
    local realm_snapshot=("${SWITCH_RULES[@]}")
    for rule in "${realm_snapshot[@]}"; do
        IFS='|' read -r lp _ <<< "$rule"
        realm_ports["$lp"]=1
    done

    parse_iptables_rules
    local ipt_snapshot=("${SWITCH_RULES[@]}")
    for rule in "${ipt_snapshot[@]}"; do
        IFS='|' read -r lp _ <<< "$rule"
        ipt_ports["$lp"]=1
    done

    echo -e "\n${YELLOW}▍Realm 规则（${#realm_snapshot[@]} 条）${NC}"
    if [[ ${#realm_snapshot[@]} -gt 0 ]]; then
        SWITCH_RULES=("${realm_snapshot[@]}")
        _preview_switch_rules realm
    else
        echo -e "  ${CYAN}（无）${NC}"
    fi

    echo -e "\n${YELLOW}▍iptables 规则（${#ipt_snapshot[@]} 条）${NC}"
    if [[ ${#ipt_snapshot[@]} -gt 0 ]]; then
        SWITCH_RULES=("${ipt_snapshot[@]}")
        _preview_switch_rules iptables
    else
        echo -e "  ${CYAN}（无）${NC}"
    fi

    # 端口冲突检查
    local conflicts=()
    for lp in "${!realm_ports[@]}"; do
        [[ -n "${ipt_ports[$lp]}" ]] && conflicts+=("$lp")
    done

    echo -e ""
    if [[ ${#conflicts[@]} -gt 0 ]]; then
        local sorted
        sorted=$(printf '%s\n' "${conflicts[@]}" | sort -n | tr '\n' ' ')
        echo -e "${YELLOW}⚠ 以下本地端口在两种方式中同时存在: ${RED}${sorted}${NC}"
        echo -e "${CYAN}  iptables 的 DNAT 发生在 PREROUTING，优先级高于 Realm 的本地监听，${NC}"
        echo -e "${CYAN}  两者同时生效时流量会被 iptables 接管。建议只保留一种。${NC}"
    else
        echo -e "${GREEN}✓ 未发现两种方式之间的端口冲突${NC}"
    fi
}

# ----------------------------------------
# 回滚到切换前状态
# ----------------------------------------
restore_switch_backup() {
    echo -e "\n${CYAN}══════════ 切换备份回滚 ══════════${NC}"

    local backups=()
    mapfile -t backups < <(ls -1dt "${SWITCH_BACKUP_DIR}"/*/ 2>/dev/null)

    if [[ ${#backups[@]} -eq 0 ]]; then
        echo -e "${YELLOW}暂无切换备份${NC}"
        echo -e "${CYAN}备份目录: ${SWITCH_BACKUP_DIR}${NC}"
        return
    fi

    echo -e ""
    printf "${YELLOW}%-5s %-22s %-18s %s${NC}\n" "序号" "时间" "方向" "规则数(Realm/iptables)"
    echo -e "${BLUE}────────────────────────────────────────────────────────────────────${NC}"

    local i=1 b meta dir_time direction rc ic dir_str
    for b in "${backups[@]}"; do
        meta="${b}meta.conf"
        dir_time=$(_meta_get "$meta" "time")
        direction=$(_meta_get "$meta" "direction")
        rc=$(_meta_get "$meta" "realm_rules")
        ic=$(_meta_get "$meta" "iptables_rules")
        case "$direction" in
            realm2iptables) dir_str="Realm ➜ iptables" ;;
            iptables2realm) dir_str="iptables ➜ Realm" ;;
            *) dir_str="${direction:-未知}" ;;
        esac
        printf "%-5s %-22s %-18s %s\n" " $i" "${dir_time:-未知}" "$dir_str" "${rc:-0} / ${ic:-0}"
        ((i++))
    done
    echo -e "${BLUE}────────────────────────────────────────────────────────────────────${NC}"
    echo -e "${CYAN}回滚将恢复该次切换前的规则文件与服务状态${NC}"
    echo -e ""

    read -rp "请输入要回滚的备份序号（回车返回）: " choice
    [[ -z "$choice" ]] && { echo "返回。"; return; }
    if ! [[ "$choice" =~ ^[0-9]+$ ]] || (( choice < 1 || choice > ${#backups[@]} )); then
        echo -e "${RED}✖ 无效序号${NC}"
        return
    fi

    local target="${backups[$((choice-1))]}"
    read -rp "确认回滚到该备份？当前规则将被覆盖 (y/N): " confirm
    [[ ! "$confirm" =~ ^[Yy]$ ]] && { echo "已取消。"; return; }

    # 回滚前再存一份当前状态，避免误操作无法挽回
    _create_switch_backup "rollback" >/dev/null

    local meta_file="${target}meta.conf"
    local was_realm_active was_realm_enabled was_chain was_ipt_enabled
    was_realm_active=$(_meta_get "$meta_file" "realm_active")
    was_realm_enabled=$(_meta_get "$meta_file" "realm_enabled")
    was_chain=$(_meta_get "$meta_file" "iptables_chain")
    was_ipt_enabled=$(_meta_get "$meta_file" "iptables_enabled")

    if [[ -f "${target}config.toml" ]]; then
        mkdir -p "$REALM_DIR"
        cp "${target}config.toml" "$CONFIG_FILE"
        echo -e "${GREEN}✓ 已恢复 Realm 配置${NC}"
    fi
    if [[ -f "${target}rules.conf" ]]; then
        mkdir -p "$IPTABLES_DIR"
        cp "${target}rules.conf" "$IPTABLES_RULES_FILE"
        echo -e "${GREEN}✓ 已恢复 iptables 规则文件${NC}"
    fi

    # 恢复 iptables 生效状态
    if command -v iptables &>/dev/null; then
        if [[ "${was_chain:-0}" =~ ^[0-9]+$ ]] && (( was_chain > 0 )); then
            echo -e "${CYAN}正在重新应用 iptables 规则...${NC}"
            apply_all_iptables_rules
            [[ "$was_ipt_enabled" == "enabled" ]] && systemctl enable iptables-forward &>/dev/null
        else
            _stop_iptables_forward
        fi
    fi

    # 恢复 Realm 服务状态
    if [[ -x "$REALM_DIR/realm" && -f "$SERVICE_FILE" ]]; then
        systemctl daemon-reload
        if [[ "$was_realm_active" == "active" ]]; then
            systemctl unmask realm.service &>/dev/null
            systemctl restart realm.service
            [[ "$was_realm_enabled" == "enabled" ]] && systemctl enable realm.service &>/dev/null
            sleep 1
            if systemctl is-active --quiet realm 2>/dev/null; then
                echo -e "${GREEN}✓ Realm 服务已恢复运行${NC}"
            else
                echo -e "${RED}✖ Realm 服务恢复失败，请检查: journalctl -u realm -n 30 --no-pager${NC}"
            fi
        else
            systemctl stop realm 2>/dev/null
            [[ "$was_realm_enabled" != "enabled" ]] && systemctl disable realm 2>/dev/null
            echo -e "${CYAN}✓ Realm 服务保持停止（与备份时一致）${NC}"
        fi
    fi

    log "已回滚到切换备份: ${target}"
    echo -e "\n${GREEN}✔ 回滚完成${NC}"
}

# ----------------------------------------
# 转发方式切换菜单
# ----------------------------------------
switch_mode_menu() {
    while true; do
        clear

        local realm_rules ipt_rules chain_rules
        realm_rules=$(_realm_rule_count)
        ipt_rules=$(_iptables_rule_count)
        chain_rules=$(_iptables_chain_count)

        local realm_state ipt_state current_mode
        if systemctl is-active --quiet realm 2>/dev/null; then
            realm_state="${GREEN}● 运行中${NC}"
        elif [[ -x "$REALM_DIR/realm" ]]; then
            realm_state="${YELLOW}○ 已停止${NC}"
        else
            realm_state="${RED}✗ 未安装${NC}"
        fi

        if (( chain_rules > 0 )); then
            ipt_state="${GREEN}● 生效中${NC}"
        elif command -v iptables &>/dev/null; then
            ipt_state="${YELLOW}○ 未生效${NC}"
        else
            ipt_state="${RED}✗ 不可用${NC}"
        fi

        local realm_on=false ipt_on=false
        systemctl is-active --quiet realm 2>/dev/null && realm_on=true
        (( chain_rules > 0 )) && ipt_on=true

        if $realm_on && $ipt_on; then
            current_mode="${YELLOW}Realm + iptables 同时启用（⚠ 端口重叠时 iptables 优先）${NC}"
        elif $realm_on; then
            current_mode="${GREEN}Realm${NC}"
        elif $ipt_on; then
            current_mode="${GREEN}iptables${NC}"
        else
            current_mode="${YELLOW}均未启用${NC}"
        fi

        echo -e ""
        echo -e "${CYAN}    ┌─────────────────────────────────────────┐${NC}"
        echo -e "${CYAN}    │      转发方式切换 (Realm ⇄ iptables)    │${NC}"
        echo -e "${CYAN}    └─────────────────────────────────────────┘${NC}"
        echo -e ""
        echo -e "    ${CYAN}◈${NC} Realm    : ${realm_state}   规则 ${GREEN}${realm_rules}${NC} 条"
        echo -e "    ${CYAN}◈${NC} iptables : ${ipt_state}   规则 ${GREEN}${ipt_rules}${NC} 条  /  NAT 条目 ${GREEN}${chain_rules}${NC} 条"
        echo -e "    ${CYAN}◈${NC} 当前转发方式: ${current_mode}"
        echo -e ""
        echo -e "${BLUE}    ┌──────────────────────────────────────────┐${NC}"
        echo -e "${BLUE}    │${NC}  ${GREEN}[1]${NC} ➜  Realm 规则迁移到 iptables         ${BLUE}│${NC}"
        echo -e "${BLUE}    │${NC}  ${GREEN}[2]${NC} ➜  iptables 规则迁移到 Realm         ${BLUE}│${NC}"
        echo -e "${BLUE}    ├──────────────────────────────────────────┤${NC}"
        echo -e "${BLUE}    │${NC}  ${GREEN}[3]${NC} 📊 规则对照 / 端口冲突检查            ${BLUE}│${NC}"
        echo -e "${BLUE}    │${NC}  ${YELLOW}[4]${NC} ⏪ 回滚到切换前状态                   ${BLUE}│${NC}"
        echo -e "${BLUE}    ├──────────────────────────────────────────┤${NC}"
        echo -e "${BLUE}    │${NC}  ${CYAN}[0]${NC} ←  返回主菜单                         ${BLUE}│${NC}"
        echo -e "${BLUE}    └──────────────────────────────────────────┘${NC}"
        echo -e ""
        echo -ne "    ${CYAN}>>>${NC} 请输入选项: "
        read -r schoice

        case $schoice in
            1)
                switch_realm_to_iptables
                read -rp "按回车键继续..."
                ;;
            2)
                switch_iptables_to_realm
                read -rp "按回车键继续..."
                ;;
            3)
                show_forward_comparison
                read -rp "按回车键继续..."
                ;;
            4)
                restore_switch_backup
                read -rp "按回车键继续..."
                ;;
            0) return ;;
            *) echo -e "${RED}无效选项！${NC}"; sleep 1 ;;
        esac
    done
}

uninstall() {
    log "开始卸载"
    echo -e "${YELLOW}▶ 正在卸载...${NC}"
    
    systemctl stop realm
    systemctl disable realm
    rm -rf "$REALM_DIR"
    rm -f "$SERVICE_FILE"
    rm -rf /root/realm
    rm -rf "$(pwd)"/realm.sh
    sed -i "/realm/d" /etc/crontab
    systemctl daemon-reload
    
    log "卸载完成"
    echo -e "${GREEN}✔ 已完全卸载！${NC}"
}

# ========================================
# 安装状态检测
# ========================================
check_installed() {
    if [[ -f "$REALM_DIR/realm" && -f "$SERVICE_FILE" ]]; then
        local version
        version=$(get_installed_version)
        if [[ -n "$version" ]]; then
            echo -e "${GREEN}已安装${NC} (v${version})"
        else
            echo -e "${GREEN}已安装${NC}"
        fi
    else
        echo -e "${RED}未安装${NC}"
    fi
}

# ========================================
# 主界面
# ========================================
main_menu() {
    clear
    init_check

    # 处理跳过更新检查参数
    local skip_update=false
    local skip_proxy=false
    for arg in "$@"; do
        case "$arg" in
            --no-update) skip_update=true ;;
            --no-proxy) skip_proxy=true ;;
        esac
    done

    # 配置代理（首次运行）
    if ! $skip_proxy; then
        setup_proxy
    else
        init_urls
    fi

    sleep 1

    # 首次运行检查更新
    if ! $skip_update; then
        check_update && perform_update "$@"
    fi

    while true; do
        # 显示代理状态
        local proxy_status
        if [[ -n "$PROXY" ]]; then
            proxy_status="${GREEN}ON${NC} ${CYAN}${PROXY}${NC}"
        else
            proxy_status="${YELLOW}OFF${NC}"
        fi

        # 服务状态图标
        local service_icon
        if systemctl is-active --quiet realm 2>/dev/null; then
            service_icon="${GREEN}● 运行中${NC}"
        else
            service_icon="${RED}○ 已停止${NC}"
        fi

        # 安装状态
        local install_icon
        if [[ -f "$REALM_DIR/realm" ]]; then
            local ver=$(get_installed_version)
            install_icon="${GREEN}✓ v${ver}${NC}"
        else
            install_icon="${RED}✗ 未安装${NC}"
        fi

        echo -e ""
        echo -e "${CYAN}    ██████╗ ███████╗ █████╗ ██╗     ███╗   ███╗${NC}"
        echo -e "${CYAN}    ██╔══██╗██╔════╝██╔══██╗██║     ████╗ ████║${NC}"
        echo -e "${CYAN}    ██████╔╝█████╗  ███████║██║     ██╔████╔██║${NC}"
        echo -e "${CYAN}    ██╔══██╗██╔══╝  ██╔══██║██║     ██║╚██╔╝██║${NC}"
        echo -e "${CYAN}    ██║  ██║███████╗██║  ██║███████╗██║ ╚═╝ ██║${NC}"
        echo -e "${CYAN}    ╚═╝  ╚═╝╚══════╝╚═╝  ╚═╝╚══════╝╚═╝     ╚═╝${NC}"
        echo -e "${YELLOW}    ─────────────────────────────────────────────${NC}"
        echo -e "           ${BLUE}TCP/UDP 转发管理面板${NC} ${GREEN}v${CURRENT_VERSION}${NC}"
        echo -e ""
        echo -e "${YELLOW}    ╔═══════════════════════════════════════════╗${NC}"
        echo -e "${YELLOW}    ║${NC}  ${CYAN}◈${NC} 服务: $service_icon                       ${YELLOW}║${NC}"
        echo -e "${YELLOW}    ║${NC}  ${CYAN}◈${NC} 安装: $install_icon                       ${YELLOW}║${NC}"
        echo -e "${YELLOW}    ║${NC}  ${CYAN}◈${NC} 代理: $proxy_status                       ${YELLOW}║${NC}"
        echo -e "${YELLOW}    ╚═══════════════════════════════════════════╝${NC}"
        echo -e ""
        echo -e "${BLUE}    ┌──────────────────────────────────────────┐${NC}"
        echo -e "${BLUE}    │${NC}  ${GREEN}[1]${NC} ⚡ 安装/更新 Realm                    ${BLUE}│${NC}"
        echo -e "${BLUE}    ├──────────────────────────────────────────┤${NC}"
        echo -e "${BLUE}    │${NC}  ${GREEN}[2]${NC} ➕ 添加转发规则（单条/批量）            ${BLUE}│${NC}"
        echo -e "${BLUE}    │${NC}  ${GREEN}[3]${NC} 📋 查看转发规则                       ${BLUE}│${NC}"
        echo -e "${BLUE}    │${NC}  ${GREEN}[4]${NC} ➖ 删除转发规则（单条/批量）            ${BLUE}│${NC}"
        echo -e "${BLUE}    ├──────────────────────────────────────────┤${NC}"
        echo -e "${BLUE}    │${NC}  ${GREEN}[5]${NC} ▶  启动服务                           ${BLUE}│${NC}"
        echo -e "${BLUE}    │${NC}  ${GREEN}[6]${NC} ■  停止服务                           ${BLUE}│${NC}"
        echo -e "${BLUE}    │${NC}  ${GREEN}[7]${NC} ↻  重启服务                           ${BLUE}│${NC}"
        echo -e "${BLUE}    ├──────────────────────────────────────────┤${NC}"
        echo -e "${BLUE}    │${NC}  ${GREEN}[8]${NC} ⏰ 定时任务管理                       ${BLUE}│${NC}"
        echo -e "${BLUE}    │${NC}  ${GREEN}[9]${NC} 📜 查看日志                           ${BLUE}│${NC}"
        echo -e "${BLUE}    ├──────────────────────────────────────────┤${NC}"
        echo -e "${BLUE}    │${NC}  ${RED}[10]${NC} 🗑  完全卸载                          ${BLUE}│${NC}"
        echo -e "${BLUE}    │${NC}  ${YELLOW}[11]${NC} 🌐 代理设置                          ${BLUE}│${NC}"
        echo -e "${BLUE}    │${NC}  ${YELLOW}[12]${NC} 📦 配置导入导出                      ${BLUE}│${NC}"
        echo -e "${BLUE}    │${NC}  ${YELLOW}[13]${NC} 🔍 DNS 解析设置                      ${BLUE}│${NC}"
        echo -e "${BLUE}    │${NC}  ${YELLOW}[14]${NC} 🔀 iptables 转发管理                 ${BLUE}│${NC}"
        echo -e "${BLUE}    │${NC}  ${YELLOW}[15]${NC} 🔁 转发方式切换 (Realm ⇄ iptables)   ${BLUE}│${NC}"
        echo -e "${BLUE}    ├──────────────────────────────────────────┤${NC}"
        echo -e "${BLUE}    │${NC}  ${CYAN}[0]${NC}  ✖  退出脚本                           ${BLUE}│${NC}"
        echo -e "${BLUE}    └──────────────────────────────────────────┘${NC}"
        echo -e ""
        echo -ne "    ${CYAN}>>>${NC} 请输入选项: "
        read -r choice
        case $choice in
            1) deploy_realm ;;
            2) add_rule ;;
            3) show_rules ;;
            4) delete_rule ;;
            5) service_control start ;;
            6) service_control stop ;;
            7) service_control restart ;;
            8) manage_cron ;;
            9) view_logs ;;
            10)
                read -rp "确认完全卸载？(y/n): " confirm
                if [[ "$confirm" == "y" ]]; then
                    uninstall
                    read -rp "按回车键继续..."
                    clear
                    exit 0
                fi
                ;;
            11) manage_proxy ;;
            12) manage_config ;;
            13) manage_dns ;;
            14) iptables_menu ;;
            15) switch_mode_menu ;;
            0) exit 0
            ;;
            *) echo -e "${RED}无效选项！${NC}" ;;
        esac
        read -rp "按回车键继续..."
        clear
    done
}

# ========================================
# 脚本入口
# ========================================
main_menu "$@"
