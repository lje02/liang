#!/bin/bash
# 公共库 - 被所有脚本共享

# 颜色
RED='\033[1;31m'
GREEN='\033[1;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
PLAIN='\033[0m'
NC='\033[0m'

# 资源路径
GITHUB_RAW_URL="https://raw.githubusercontent.com/lje02/liang/main/vp/vp"
SINGBOX_INSTALL_URL="https://raw.githubusercontent.com/lje02/sing/main/install.sh"

# 临时文件清理
cleanup() {
    rm -f /tmp/vp_latest.sh
}
trap cleanup EXIT

# 提权检测
check_root() {
    if [[ $EUID -ne 0 ]]; then
        printf "${RED}错误：此脚本必须由 root 用户执行。${PLAIN}\n"
        exit 1
    fi
}

# 系统识别
detect_os() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        OS=$ID
        OS_LIKE=$ID_LIKE
    else
        printf "${RED}无法检测系统类型${PLAIN}\n"
        exit 1
    fi

    case "$OS" in
        debian|ubuntu|kali|raspbian) OS_FAMILY="debian" ;;
        centos|rhel|fedora|rocky|alma) OS_FAMILY="rhel" ;;
        *)
            if [[ "$OS_LIKE" =~ (debian|ubuntu) ]]; then OS_FAMILY="debian"
            elif [[ "$OS_LIKE" =~ (rhel|fedora|centos) ]]; then OS_FAMILY="rhel"
            else printf "${RED}不支持的系统：$OS${PLAIN}\n"; exit 1; fi
            ;;
    esac
}

# 依赖补齐
check_dependencies() {
    local deps=(
        "curl:curl"
        "jq:jq"
        "openssl:openssl"
        "ss:iproute2"
        "gawk:gawk"
        "realpath:coreutils"
        "diff:diffutils"
        "ssh-copy-id:openssh-client"
    )
    local missing_packages=()
    for item in "${deps[@]}"; do
        local cmd="${item%%:*}"
        local pkg="${item#*:}"
        if ! command -v "$cmd" &>/dev/null; then
            missing_packages+=("$pkg")
        fi
    done

    if [ ${#missing_packages[@]} -ne 0 ]; then
        printf "${BLUE}正在补齐必要工具: ${missing_packages[*]}...${PLAIN}\n"
        if [ "$OS_FAMILY" = "debian" ]; then
            apt-get update -qq && apt-get install -y "${missing_packages[@]}" || {
                printf "${RED}依赖安装失败，请手动安装后重试${PLAIN}\n"
                exit 1
            }
        else
            yum install -y "${missing_packages[@]}" || {
                printf "${RED}依赖安装失败，请手动安装后重试${PLAIN}\n"
                exit 1
            }
        fi
    fi
}

# 获取 SSH 端口
get_ssh_port() {
    local port
    port=$(ss -tlnp | grep -Po ':\d+ (?=.*sshd)' | head -1 | grep -Po '\d+')
    if [ -z "$port" ]; then
        port=$(grep -E "^#?Port " /etc/ssh/sshd_config | awk '{print $2}' | head -1)
    fi
    echo "${port:-22}"
}

# 标记已加载
VPS_COMMON_LOADED=true
