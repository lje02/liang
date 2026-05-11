#!/bin/bash
# 防火墙与 Fail2Ban 模块

if [ -z "$VPS_COMMON_LOADED" ]; then
    source /usr/local/share/vp_modules/common.sh 2>/dev/null || {
        echo "无法加载公共函数库"
        exit 1
    }
fi
detect_os
check_dependencies

# -------- 防火墙 --------
detect_firewall() {
    if command -v ufw &>/dev/null; then
        if ufw status | grep -q "Status: active"; then
            printf "${GREEN}UFW 运行中${NC}\n"
        else
            printf "${YELLOW}UFW 已安装（未运行）${NC}\n"
        fi
    elif command -v firewall-cmd &>/dev/null; then
        if firewall-cmd --state 2>/dev/null | grep -q "running"; then
            printf "${GREEN}firewalld 运行中${NC}\n"
        else
            printf "${YELLOW}firewalld 已安装（未运行）${NC}\n"
        fi
    elif command -v iptables &>/dev/null; then
        # iptables 检测：如果 INPUT 链有非 ACCEPT 策略或存在额外规则，视为“运行中”
        local policy=$(iptables -L INPUT -n 2>/dev/null | head -1 | awk '{print $4}')
        local rules_count=$(iptables -L INPUT -n 2>/dev/null | grep -c '^[0-9]')
        if [ "$policy" != "ACCEPT" ] || [ "$rules_count" -gt 0 ]; then
            printf "${GREEN}iptables 运行中${NC}\n"
        else
            printf "${YELLOW}iptables 已安装（未运行）${NC}\n"
        fi
    else
        printf "${RED}未安装${NC}\n"
    fi
}

install_firewall() {
    local ssh_port=$(get_ssh_port)
    printf "${BLUE}正在安装防火墙...${NC}\n"
    if [ "$OS_FAMILY" = "debian" ]; then
        apt-get update -qq && apt-get install -y ufw || {
            printf "${RED}UFW 安装失败${NC}\n"; return
        }
        ufw allow "$ssh_port"/tcp      # 预置 SSH 规则
        printf "${GREEN}UFW 安装完成，SSH 端口已预放行（防火墙未启用）${NC}\n"
    else
        yum install -y firewalld || {
            printf "${RED}firewalld 安装失败${NC}\n"; return
        }
        systemctl start firewalld && systemctl enable firewalld
        firewall-cmd --zone=public --add-service=ssh --permanent
        firewall-cmd --reload
        printf "${GREEN}firewalld 安装并已启用，SSH 服务已放行${NC}\n"
    fi
}

enable_firewall() {
    local ssh_port=$(get_ssh_port)   # 动态获取当前 SSH 端口
    if command -v ufw &>/dev/null; then
        ufw allow "$ssh_port"/tcp     # 提前放行 SSH
        ufw --force enable
        systemctl enable ufw
        printf "${GREEN}UFW 已开启，SSH 端口 $ssh_port 已放行，并设为开机自启${NC}\n"
    elif command -v firewall-cmd &>/dev/null; then
        firewall-cmd --zone=public --add-service=ssh --permanent 2>/dev/null || \
        firewall-cmd --zone=public --add-port="${ssh_port}/tcp" --permanent
        firewall-cmd --reload
        systemctl start firewalld && systemctl enable firewalld
        printf "${GREEN}firewalld 已开启，SSH 服务已放行，并设为开机自启${NC}\n"
    else
        printf "${RED}未找到防火墙，请先安装${NC}\n"
    fi
}

open_all_ports() {
    local ssh_port=$(get_ssh_port)
    printf "${YELLOW}开放全部端口前，已确保 SSH($ssh_port) 不被禁用${NC}\n"
    if command -v ufw &>/dev/null; then
        ufw default allow incoming
        ufw allow "$ssh_port"/tcp
        printf "${GREEN}UFW 默认策略已设为 ALLOW${NC}\n"
    elif command -v firewall-cmd &>/dev/null; then
        firewall-cmd --set-default-zone=trusted
        firewall-cmd --zone=trusted --add-service=ssh --permanent
        firewall-cmd --reload
        printf "${GREEN}firewalld 默认区域已设为 trusted（全部放行）${NC}\n"
    elif command -v iptables &>/dev/null; then
        iptables -P INPUT ACCEPT; iptables -P FORWARD ACCEPT; iptables -P OUTPUT ACCEPT; iptables -F
        printf "${GREEN}iptables 默认策略已改为 ACCEPT${NC}\n"
    fi
}

close_all_ports() {
    local ssh_port=$(get_ssh_port)
    printf "${RED}⚠ 关闭全部端口可能导致你失去 SSH 连接！${NC}\n"
    read -p "是否保留 SSH 端口？(推荐保留) [Y/n]: " keep_ssh
    keep_ssh=${keep_ssh:-Y}
    local open_ssh=false
    [[ $keep_ssh =~ ^[Yy]$ ]] && open_ssh=true

    if command -v ufw &>/dev/null; then
        ufw --force reset
        ufw default deny incoming
        ufw default allow outgoing
        $open_ssh && ufw allow "$ssh_port"/tcp
        ufw --force enable
        printf "${GREEN}UFW 已重置，仅保留必要端口${NC}\n"
    elif command -v firewall-cmd &>/dev/null; then
        firewall-cmd --set-default-zone=public
        firewall-cmd --zone=public --remove-service=ssh --permanent 2>/dev/null
        $open_ssh && firewall-cmd --zone=public --add-port="${ssh_port}/tcp" --permanent
        firewall-cmd --reload
        printf "${GREEN}firewalld 默认区域已设为 public，仅开放必要端口${NC}\n"
    elif command -v iptables &>/dev/null; then
        iptables -P INPUT DROP; iptables -P FORWARD DROP; iptables -P OUTPUT ACCEPT; iptables -F
        $open_ssh && iptables -A INPUT -p tcp --dport "$ssh_port" -j ACCEPT
        iptables -A INPUT -m state --state ESTABLISHED,RELATED -j ACCEPT
        printf "${GREEN}iptables 已配置为 DROP 所有入站（SSH: $open_ssh）${NC}\n"
    fi
}

open_ports() {
    read -p "请输入要开放的端口（多个用空格分隔，支持范围如 1000:2000）：" ports
    [[ -z "$ports" ]] && printf "${RED}未输入任何端口${NC}\n" && return
    if command -v ufw &>/dev/null; then
        for port in $ports; do
            if [[ $port == *:* ]]; then
                ufw allow proto tcp to any port $port
            else
                ufw allow $port
            fi
        done
        printf "${GREEN}UFW 规则已添加${NC}\n"
    elif command -v firewall-cmd &>/dev/null; then
        for port in $ports; do firewall-cmd --zone=public --add-port="${port}/tcp" --permanent; done
        firewall-cmd --reload
        printf "${GREEN}firewalld 端口已开放${NC}\n"
    elif command -v iptables &>/dev/null; then
        for port in $ports; do
            if [[ $port == *:* ]]; then
                start=$(echo $port | cut -d: -f1); end=$(echo $port | cut -d: -f2)
                iptables -A INPUT -p tcp --dport "${start}:${end}" -j ACCEPT
            else
                iptables -A INPUT -p tcp --dport "$port" -j ACCEPT
            fi
        done
        printf "${GREEN}iptables 规则已添加${NC}\n"
    fi
}

close_ports() {
    read -p "请输入要关闭的端口（多个用空格分隔）：" ports
    [[ -z "$ports" ]] && printf "${RED}未输入任何端口${NC}\n" && return
    if command -v ufw &>/dev/null; then
        for port in $ports; do ufw deny $port; done
        printf "${GREEN}UFW 拒绝规则已添加${NC}\n"
    elif command -v firewall-cmd &>/dev/null; then
        for port in $ports; do firewall-cmd --zone=public --remove-port="${port}/tcp" --permanent; done
        firewall-cmd --reload
        printf "${GREEN}firewalld 端口已关闭${NC}\n"
    elif command -v iptables &>/dev/null; then
        for port in $ports; do iptables -D INPUT -p tcp --dport "$port" -j ACCEPT 2>/dev/null || true; done
        printf "${GREEN}iptables 规则已尝试删除${NC}\n"
    fi
}

show_firewall_status() {
    clear
    printf "${BLUE}===== 防火墙详细状态 =====${NC}\n"
    if command -v ufw &>/dev/null && ufw status | grep -q "Status: active"; then
        printf "${GREEN}UFW 状态:${NC}\n"
        ufw status verbose
    elif command -v firewall-cmd &>/dev/null && firewall-cmd --state 2>/dev/null | grep -q "running"; then
        printf "${GREEN}firewalld 状态:${NC}\n"
        firewall-cmd --state
        echo ""
        printf "默认区域: %s\n" "$(firewall-cmd --get-default-zone)"
        for zone in $(firewall-cmd --get-active-zones | grep -v "interfaces\|sources" | tr ' ' '\n' | grep -v '^$'); do
            printf "\n区域: %s\n" "$zone"
            firewall-cmd --zone="$zone" --list-all
        done
    elif command -v iptables &>/dev/null; then
        printf "${YELLOW}iptables 规则 (无 UFW/firewalld 管理):${NC}\n"
        iptables -L INPUT -n -v --line-numbers 2>/dev/null
        iptables -L FORWARD -n -v --line-numbers 2>/dev/null
        iptables -L OUTPUT -n -v --line-numbers 2>/dev/null
    else
        printf "${RED}未检测到活动的防火墙${NC}\n"
    fi
    echo ""
    read -p "按回车键继续..." dummy
}

# -------- Fail2Ban --------
detect_fail2ban() {
    if command -v fail2ban-client &>/dev/null; then
        if pgrep -x fail2ban-server &>/dev/null; then
            printf "${GREEN}已安装（运行中）${NC}\n"
        else
            printf "${YELLOW}已安装（未运行）${NC}\n"
        fi
    else
        printf "${RED}未安装${NC}\n"
    fi
}

install_fail2ban() {
    printf "${BLUE}正在安装 Fail2Ban...${NC}\n"
    if [ "$OS_FAMILY" = "debian" ]; then
        apt-get update -qq && apt-get install -y fail2ban iptables || {
            printf "${RED}Fail2Ban 安装失败${NC}\n"; return
        }
    else
        yum install -y epel-release && yum install -y fail2ban iptables || {
            printf "${RED}Fail2Ban 安装失败${NC}\n"; return
        }
    fi

    local jail_local="/etc/fail2ban/jail.local"
    [ ! -f "$jail_local" ] && cp /etc/fail2ban/jail.conf "$jail_local"

    if ! [ -f /var/log/auth.log ] && command -v journalctl &>/dev/null; then
        if grep -q '^\[sshd\]' "$jail_local"; then
            sed -i '/^\[sshd\]/,/^\[/ s/^backend.*/backend = systemd/' "$jail_local"
        else
            echo -e "[sshd]\nbackend = systemd" >> "$jail_local"
        fi
    fi

    if command -v systemctl &>/dev/null; then
        systemctl enable fail2ban && systemctl start fail2ban
    else
        chkconfig fail2ban on 2>/dev/null || update-rc.d fail2ban defaults 2>/dev/null
        service fail2ban start
    fi

    sleep 2
    if pgrep -x fail2ban-server &>/dev/null; then
        printf "${GREEN}Fail2Ban 安装完成并已启动${NC}\n"
    else
        printf "${RED}Fail2Ban 安装后未能启动，请检查: journalctl -u fail2ban${NC}\n"
    fi
}

show_ban_records() {
    if ! command -v fail2ban-client &>/dev/null; then
        printf "${RED}Fail2Ban 未安装${NC}\n"; return
    fi
    printf "${BLUE}==== 拦截记录 ====${NC}\n"
    fail2ban-client status
    for jail in $(fail2ban-client status | grep "Jail list" | cut -d: -f2 | tr -d ','); do
        printf "${GREEN}-- $jail --${NC}\n"
        fail2ban-client status "$jail"
        echo ""
    done
}

config_fail2ban() {
    if ! command -v fail2ban-client &>/dev/null; then
        printf "${RED}Fail2Ban 未安装${NC}\n"; return
    fi
    local conf_file="/etc/fail2ban/jail.local"
    [ ! -f "$conf_file" ] && cp /etc/fail2ban/jail.conf "$conf_file"

    read -p "封禁时长(秒, 默认600): " bantime; bantime=${bantime:-600}
    read -p "时间窗口(秒, 默认600): " findtime; findtime=${findtime:-600}
    read -p "最大尝试次数(默认5): " maxretry; maxretry=${maxretry:-5}

    sed -i "s/^bantime.*=.*/bantime = $bantime/" "$conf_file"
    sed -i "s/^findtime.*=.*/findtime = $findtime/" "$conf_file"
    sed -i "s/^maxretry.*=.*/maxretry = $maxretry/" "$conf_file"

    if fail2ban-server -t &>/dev/null; then
        systemctl restart fail2ban 2>/dev/null || service fail2ban restart
        printf "${GREEN}参数已更新，Fail2Ban 已重启${NC}\n"
    else
        printf "${RED}配置语法错误，请检查 $conf_file${NC}\n"
    fi
}

uninstall_fail2ban() {
    read -p "确定要卸载 Fail2Ban 吗？[y/N] " confirm
    [[ ! $confirm =~ ^[Yy]$ ]] && return
    systemctl stop fail2ban 2>/dev/null; systemctl disable fail2ban 2>/dev/null
    if [ "$OS_FAMILY" = "debian" ]; then apt-get purge -y fail2ban; else yum remove -y fail2ban; fi
    printf "${GREEN}Fail2Ban 已卸载${NC}\n"
}

fail2ban_menu() {
    while true; do
        clear
        printf "${BLUE}===== Fail2Ban 管理 =====${NC}\n"
        printf "当前状态："; detect_fail2ban
        echo "1. 安装 Fail2Ban"
        echo "2. 查看拦截记录"
        echo "3. 基础参数配置"
        echo "4. 卸载 Fail2Ban"
        echo "0. 返回上级菜单"
        read -p "请选择操作: " fb_choice
        case $fb_choice in
            1) install_fail2ban ;;
            2) show_ban_records ;;
            3) config_fail2ban ;;
            4) uninstall_fail2ban ;;
            0) break ;;
            *) printf "${RED}无效选项${NC}\n" ;;
        esac
        echo ""; read -p "按回车键继续..." dummy
    done
}

# 组合菜单
firewall_menu() {
    while true; do
        clear
        printf "${BLUE}===== 防火墙 / Fail2Ban 管理 =====${NC}\n"
        printf "当前防火墙状态："; detect_firewall
        printf "当前 Fail2Ban 状态："; detect_fail2ban
        echo "--------------------------------------"
        echo "1. 安装防火墙"
        echo "2. 开启防火墙"
        echo "3. 开放全部端口"
        echo "4. 关闭全部端口"
        echo "5. 开放指定端口"
        echo "6. 关闭指定端口"
        echo "7. 查看防火墙详细状态"
        echo "--------------------------------------"
        echo "8. Fail2Ban 管理"
        echo "0. 返回主菜单"
        read -p "请选择操作: " fw_choice
        case $fw_choice in
            1) install_firewall ;;
            2) enable_firewall ;;
            3) open_all_ports ;;
            4) close_all_ports ;;
            5) open_ports ;;
            6) close_ports ;;
            7) show_firewall_status ;;
            8) fail2ban_menu ;;
            0) break ;;
            *) printf "${RED}无效选项${NC}\n" ;;
        esac
    done
}

firewall_menu
