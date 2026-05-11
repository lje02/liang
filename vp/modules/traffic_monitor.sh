#!/bin/bash
# 流量监控模块 (基于 vnstat)

if [ -z "$VPS_COMMON_LOADED" ]; then
    source /usr/local/share/vp_modules/common.sh 2>/dev/null || {
        echo "无法加载公共函数库"
        exit 1
    }
fi

detect_os
check_dependencies

# ---------- 自动安装 vnstat ----------
ensure_vnstat() {
    if ! command -v vnstat &>/dev/null; then
        printf "${BLUE}正在安装流量监控工具 vnstat...${NC}\n"
        if [ "$OS_FAMILY" = "debian" ]; then
            apt-get update -qq && apt-get install -y vnstat
        else
            yum install -y epel-release 2>/dev/null || true
            yum install -y vnstat
        fi
        # 初始化数据库
        vnstatd -n --daemon 2>/dev/null || systemctl enable --now vnstat 2>/dev/null || service vnstat start 2>/dev/null
        sleep 2
        printf "${GREEN}vnstat 已安装并启动。${NC}\n"
    fi
}

# ---------- 获取网络接口列表 ----------
get_interfaces() {
    ip -br link | awk '{print $1}' | grep -v lo
}

# ---------- 实时带宽 ----------
live_traffic() {
    local iface="$1"
    printf "${GREEN}实时流量监控 (接口: %s)${NC}\n" "$iface"
    printf "按 Ctrl+C 退出...\n\n"
    vnstat -l -i "$iface"
}

# ---------- 查看统计 ----------
view_stats() {
    local iface="$1"
    printf "${BLUE}===== 流量统计 (接口: $iface) =====${NC}\n"
    echo "1. 今日流量"
    echo "2. 本月流量"
    echo "3. 总量统计"
    echo "0. 返回"
    read -p "选择: " stat_choice
    case $stat_choice in
        1) vnstat -i "$iface" -d | tail -3 ;;
        2) vnstat -i "$iface" -m | tail -3 ;;
        3) vnstat -i "$iface" -t ;;
        0) return ;;
        *) printf "${RED}无效选项${NC}\n" ;;
    esac
}

# ---------- 选择接口 ----------
select_interface() {
    local ifaces=($(get_interfaces))
    if [ ${#ifaces[@]} -eq 0 ]; then
        printf "${RED}未检测到可监控的网络接口${NC}\n"
        return 1
    fi
    echo "可用的网络接口："
    for i in "${!ifaces[@]}"; do
        printf "%d. %s\n" $((i+1)) "${ifaces[$i]}"
    done
    read -p "请选择接口编号 (默认1): " if_choice
    if_choice=${if_choice:-1}
    if [[ $if_choice =~ ^[0-9]+$ ]] && [ "$if_choice" -ge 1 ] && [ "$if_choice" -le "${#ifaces[@]}" ]; then
        echo "${ifaces[$((if_choice-1))]}"
    else
        echo "${ifaces[0]}"
    fi
}

# ---------- 主菜单 ----------
traffic_menu() {
    ensure_vnstat
    while true; do
        clear
        printf "${BLUE}===== 流量监控 =====${NC}\n"
        echo "1. 实时流量监控"
        echo "2. 查看统计数据"
        echo "3. 切换监控接口"
        echo "0. 返回主菜单"
        if [ -z "$CURRENT_IFACE" ]; then
            CURRENT_IFACE=$(get_interfaces | head -1)
        fi
        printf "当前接口: ${GREEN}%s${NC}\n" "$CURRENT_IFACE"
        read -p "请选择: " main_choice

        case $main_choice in
            1)
                if [ -n "$CURRENT_IFACE" ]; then
                    live_traffic "$CURRENT_IFACE"
                else
                    printf "${RED}未选择接口${NC}\n"
                    sleep 1
                fi
                ;;
            2)
                if [ -n "$CURRENT_IFACE" ]; then
                    view_stats "$CURRENT_IFACE"
                else
                    printf "${RED}未选择接口${NC}\n"
                fi
                read -p "按回车键继续..." dummy
                ;;
            3)
                CURRENT_IFACE=$(select_interface)
                ;;
            0) break ;;
            *) printf "${RED}无效选项${NC}\n" && sleep 1 ;;
        esac
    done
}

traffic_menu
