#!/bin/bash
# 模块：防火墙与Fail2Ban管理

if [ -z "$VPS_COMMON_LOADED" ]; then
    source /usr/local/share/vps_modules/common.sh 2>/dev/null || {
        echo "无法加载公共函数库"
        exit 1
    }
fi

# ==================== 防火墙 ====================
detect_firewall() {
    # …… 保持原样，无需修改 ……
}

install_firewall() {
    # ……
}

enable_firewall() {
    # ……
}

open_all_ports() {
    # ……
}

close_all_ports() {
    # ……
}

open_ports() {
    # ……
}

close_ports() {
    # ……
}

show_firewall_status() {
    # ……
}

# ==================== Fail2Ban ===================
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
    # …… 包含自动适配 systemd backend ……
}

show_ban_records() {
    # ……
}

config_fail2ban() {
    # …… 添加 fail2ban-server -t 检查 ……
}

uninstall_fail2ban() {
    # ……
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
        echo ""; read -p "按回车键继续..." dummy
    done
}

# 直接运行模块时，进入防火墙菜单
firewall_menu