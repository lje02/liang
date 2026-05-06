#!/bin/bash

if [ -z "$VPS_COMMON_LOADED" ]; then
    source /usr/local/share/vp_modules/common.sh 2>/dev/null || {
        echo "无法加载公共函数库"
        exit 1
    }
fi

detect_os
check_dependencies

CONFIG_FILE="/usr/local/etc/sing-box/config.json"
SERVICE_NAME="sing-box"

# 检查 sing-box 状态
check_singbox() {
    if command -v sing-box &>/dev/null; then
        if systemctl is-active --quiet sing-box 2>/dev/null || pgrep -x sing-box &>/dev/null; then
            printf "${GREEN}运行中${NC}"
        else
            printf "${YELLOW}已安装（未运行）${NC}"
        fi
    else
        printf "${RED}未安装${NC}"
    fi
}

# 安装
install_singbox() {
    printf "${BLUE}正在安装 sing-box...${NC}\n"
    bash <(curl -sSL "$SINGBOX_INSTALL_URL") || {
        printf "${RED}安装失败，请检查网络。${NC}\n"
        read -p "按回车继续..." dummy
        return 1
    }
    printf "${GREEN}安装完成！${NC}\n"
    read -p "按回车继续..." dummy
}

# 启动/停止/重启/状态
manage_service() {
    if ! command -v sing-box &>/dev/null; then
        printf "${RED}sing-box 未安装${NC}\n"
        read -p "按回车继续..." dummy
        return
    fi

    while true; do
        clear
        printf "${BLUE}===== sing-box 服务管理 =====${NC}\n"
        printf "状态: "; check_singbox
        echo ""
        echo "1. 启动 sing-box"
        echo "2. 停止 sing-box"
        echo "3. 重启 sing-box"
        echo "4. 查看运行日志"
        echo "0. 返回"
        read -p "选择: " svc_choice
        case $svc_choice in
            1) systemctl start sing-box 2>/dev/null || service sing-box start
               printf "${GREEN}已启动${NC}\n"; sleep 1 ;;
            2) systemctl stop sing-box 2>/dev/null || service sing-box stop
               printf "${YELLOW}已停止${NC}\n"; sleep 1 ;;
            3) systemctl restart sing-box 2>/dev/null || service sing-box restart
               printf "${GREEN}已重启${NC}\n"; sleep 1 ;;
            4) journalctl -u sing-box -n 50 --no-pager 2>/dev/null || tail -50 /var/log/sing-box.log 2>/dev/null || echo "无日志"
               read -p "按回车继续..." dummy ;;
            0) break ;;
            *) printf "${RED}无效选项${NC}\n"; sleep 1 ;;
        esac
    done
}

# 查看/编辑配置
config_menu() {
    if ! command -v sing-box &>/dev/null; then
        printf "${RED}sing-box 未安装${NC}\n"
        read -p "按回车继续..." dummy
        return
    fi

    while true; do
        clear
        printf "${BLUE}===== sing-box 配置管理 =====${NC}\n"
        echo "1. 查看配置"
        echo "2. 编辑配置 (nano)"
        echo "3. 验证配置语法"
        echo "0. 返回"
        read -p "选择: " cfg_choice
        case $cfg_choice in
            1)
                if [ -f "$CONFIG_FILE" ]; then
                    cat "$CONFIG_FILE"
                else
                    printf "${RED}配置文件不存在: $CONFIG_FILE${NC}\n"
                fi
                read -p "按回车继续..." dummy ;;
            2)
                if [ -f "$CONFIG_FILE" ]; then
                    nano "$CONFIG_FILE"
                else
                    printf "${RED}配置文件不存在: $CONFIG_FILE${NC}\n"
                    read -p "按回车继续..." dummy
                fi ;;
            3)
                if [ -f "$CONFIG_FILE" ]; then
                    sing-box check -c "$CONFIG_FILE" 2>/dev/null && \
                    printf "${GREEN}配置有效${NC}\n" || printf "${RED}配置有误${NC}\n"
                else
                    printf "${RED}配置文件不存在${NC}\n"
                fi
                read -p "按回车继续..." dummy ;;
            0) break ;;
            *) printf "${RED}无效选项${NC}\n"; sleep 1 ;;
        esac
    done
}

# 主菜单
singbox_menu() {
    while true; do
        clear
        printf "${BLUE}===== sing-box 管理 =====${NC}\n"
        printf "状态: "; check_singbox
        echo ""
        echo "1. 安装/重新安装"
        echo "2. 服务管理 (启动/停止/日志)"
        echo "3. 配置管理 (查看/编辑)"
        echo "0. 返回主菜单"
        read -p "请选择: " choice
        case $choice in
            1) install_singbox ;;
            2) manage_service ;;
            3) config_menu ;;
            0) break ;;
            *) printf "${RED}无效选项${NC}\n"; sleep 1 ;;
        esac
    done
}

singbox_menu