#!/bin/bash
# 系统实时监控模块

if [ -z "$VPS_COMMON_LOADED" ]; then
    source /usr/local/share/vp_modules/common.sh 2>/dev/null || {
        echo "无法加载公共函数库"
        exit 1
    }
fi

show_dashboard() {
    clear
    printf "${GREEN}========== 系统实时监控 (按 Q 退出) ==========${NC}\n"
    printf "主机名   : %s\n" "$(hostname)"
    printf "运行时间 : %s\n" "$(uptime -p)"
    echo ""

    # 系统负载
    printf "${YELLOW}--- 系统负载 ---${NC}\n"
    uptime | awk -F'load average:' '{print "负载 (1/5/15):" $2}'
    echo ""

    # CPU 与进程
    printf "${YELLOW}--- CPU ---${NC}\n"
    printf "CPU 核心 : %s\n" "$(nproc)"
    printf "进程总数 : %s\n" "$(ps aux --no-headers 2>/dev/null | wc -l)"
    echo ""

    # 内存
    printf "${YELLOW}--- 内存 ---${NC}\n"
    free -h | grep -E "^Mem:|^Swap:"
    echo ""

    # 磁盘
    printf "${YELLOW}--- 磁盘使用 ---${NC}\n"
    df -h / $(ls /boot 2>/dev/null && echo /boot) 2>/dev/null
    echo ""

    # 网络累计流量
    printf "${YELLOW}--- 网络接口累计流量 ---${NC}\n"
    for iface in $(ip -br link | awk '{print $1}' | grep -v lo); do
        ip -s link show "$iface" 2>/dev/null | awk '
          /^[[:space:]]+[0-9]+:/ { iface=substr($2,1,length($2)-1) }
          /RX:/{ rx=$1 } /TX:/{ tx=$1 }
          END{ if(rx!="") printf "%-8s RX: %'"'"'d bytes   TX: %'"'"'d bytes\n", iface, rx, tx }' iface="$iface"
    done
    echo ""

    # TOP 5 CPU 进程
    printf "${YELLOW}--- CPU 占用 TOP 5 ---${NC}\n"
    ps aux --sort=-%cpu --no-headers 2>/dev/null | head -5 | awk '{printf "%-10s PID:%-6s CPU:%-5s MEM:%-5s %s\n", $1, $2, $3"%", $4"%", $11}'
    echo ""
}

# 监控主循环
printf "${GREEN}进入实时监控模式，按 Q 键退出。${NC}\n"
sleep 1
while true; do
    show_dashboard
    read -t 2 -n 1 key
    if [[ "$key" == "q" || "$key" == "Q" ]]; then
        break
    fi
done

printf "${GREEN}监控已退出。${NC}\n"
read -p "按回车键返回主菜单..." dummy
