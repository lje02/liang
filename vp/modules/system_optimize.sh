#!/bin/bash
# 系统信息与优化模块

if [ -z "$VPS_COMMON_LOADED" ]; then
    source /usr/local/share/vp_modules/common.sh 2>/dev/null || {
        echo "无法加载公共函数库"
        exit 1
    }
fi
detect_os
check_dependencies

show_system_info() {
    clear
    printf "${BLUE}========== 系统信息 ==========${NC}\n"
    printf "主机名: %s\n" "$(hostname)"
    printf "操作系统: %s\n" "$(cat /etc/os-release | grep PRETTY_NAME | cut -d= -f2 | tr -d '"')"
    printf "内核版本: %s\n" "$(uname -r)"
    printf "CPU 型号: %s\n" "$(lscpu | grep 'Model name' | cut -d: -f2 | xargs)"
    printf "CPU 核心数: %s\n" "$(nproc)"
    printf "内存: %s\n" "$(free -h | grep Mem | awk '{print $2}')"
    printf "磁盘使用: %s\n" "$(df -h / | awk 'NR==2 {print $3 "/" $2 " (" $5 ")"}')"
    printf "运行时间: %s\n" "$(uptime -p)"

    printf "\n${BLUE}========== 网络信息 ==========${NC}\n"
    echo "=== 网卡地址 ==="
    ip -br addr | grep -v "lo"
    echo ""
    echo "=== 默认网关 ==="
    ip route | grep default
    echo ""
    echo "=== DNS 服务器 ==="
    cat /etc/resolv.conf | grep nameserver
    echo ""
    read -p "按回车键继续..." dummy
}

install_bbr() {
    clear
    printf "${BLUE}===== BBR 加速状态与设置 =====${NC}\n"
    local kernel_full=$(uname -r)
    local kernel_ver=$(echo "$kernel_full" | cut -d. -f1-2)
    printf "当前内核版本: %s\n" "$kernel_full"

    local current_cc
    current_cc=$(sysctl net.ipv4.tcp_congestion_control 2>/dev/null | awk '{print $3}')
    printf "当前拥塞控制算法: %s\n" "${current_cc:-未知}"
    printf "当前队列算法: %s\n" "$(sysctl net.core.default_qdisc 2>/dev/null | awk '{print $3}' || echo '未知')"

    if [ "$current_cc" = "bbr" ]; then
        printf "${GREEN}BBR 已启用！${NC}\n"
        read -p "按回车键返回..." dummy
        return
    fi

    if ! printf '%s\n' "$kernel_ver" "4.9" | sort -V | head -1 | grep -q "4.9"; then
        printf "${RED}内核版本过低（当前 %s，需要 >= 4.9），不支持 BBR。${NC}\n" "$kernel_ver"
        read -p "按回车键返回..." dummy
        return
    fi

    printf "${YELLOW}BBR 未启用，是否立即开启？[Y/n]: ${NC}"
    read -p "" confirm
    if [[ ! $confirm =~ ^[Yy]?$ ]]; then
        return
    fi

    sed -i '/net.core.default_qdisc/d' /etc/sysctl.conf
    sed -i '/net.ipv4.tcp_congestion_control/d' /etc/sysctl.conf
    echo "net.core.default_qdisc = fq" >> /etc/sysctl.conf
    echo "net.ipv4.tcp_congestion_control = bbr" >> /etc/sysctl.conf
    if sysctl -p &>/dev/null; then
        printf "${GREEN}BBR 加速已激活！${NC}\n"
        printf "新拥塞控制算法: %s\n" "$(sysctl net.ipv4.tcp_congestion_control | awk '{print $3}')"
    else
        printf "${RED}sysctl 应用失败，请检查配置。${NC}\n"
    fi
    read -p "按回车键继续..." dummy
}

config_swap() {
    clear
    printf "${BLUE}当前 Swap 状态：${NC}\n"; swapon --show; echo ""
    read -p "输入要创建的 Swap 大小 (MB) [例如 1024]，0 取消: " swap_size
    [[ -z "$swap_size" || "$swap_size" -eq 0 ]] && return
    if [[ $swap_size =~ ^[0-9]+$ ]]; then
        if swapon --show | grep -q "swapfile"; then swapoff /swapfile; rm -f /swapfile; fi
        dd if=/dev/zero of=/ swapfile bs=1M count=$swap_size status=progress
        chmod 600 /swapfile; mkswap /swapfile; swapon /swapfile
        grep -q "/swapfile" /etc/fstab || echo "/swapfile none swap sw 0 0" >> /etc/fstab
        printf "${GREEN}Swap 创建成功，大小 ${swap_size}MB${NC}\n"
    else
        printf "${RED}输入的不是有效数字${NC}\n"
    fi
    read -p "按回车键继续..." dummy
}

system_opt_menu() {
    while true; do
        clear
        printf "${BLUE}===== 系统信息与优化 =====${NC}\n"
        echo "1. 查看系统与网络信息"
        echo "2. 安装/开启 BBR"
        echo "3. 虚拟内存配置 (Swap)"
        echo "0. 返回上级菜单"
        read -p "请选择: " opt_choice
        case $opt_choice in
            1) show_system_info ;;
            2) install_bbr ;;
            3) config_swap ;;
            0) break ;;
            *) printf "${RED}无效选项${NC}\n" ;;
        esac
    done
}

system_opt_menu
