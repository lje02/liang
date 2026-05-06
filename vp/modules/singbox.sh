#!/bin/bash
# sing-box 管理模块

if [ -z "$VPS_COMMON_LOADED" ]; then
    source /usr/local/share/vp_modules/common.sh 2>/dev/null || {
        echo "无法加载公共函数库"
        exit 1
    }
fi

detect_os
check_dependencies

# ----------------- 路径检测（适配多种安装方式） -----------------
find_singbox() {
    # 尝试多个常见路径
    for path in /usr/local/bin/sing-box /usr/bin/sing-box /opt/sing-box/sing-box; do
        if [ -x "$path" ]; then
            SINGBOX_BIN="$path"
            return 0
        fi
    done
    # 最后通过 which 查找
    if command -v sing-box &>/dev/null; then
        SINGBOX_BIN="sing-box"
        return 0
    fi
    return 1
}

# ----------------- 状态检查 -----------------
check_status() {
    if find_singbox; then
        if systemctl is-active --quiet sing-box 2>/dev/null || pgrep -x sing-box &>/dev/null; then
            printf "${GREEN}运行中${NC}"
        else
            printf "${YELLOW}已安装（未运行）${NC}"
        fi
    else
        printf "${RED}未安装${NC}"
    fi
}

# ----------------- 安装 -----------------
do_install() {
    printf "${BLUE}正在安装 sing-box...${NC}\n"
    if bash <(curl -sSL "$SINGBOX_INSTALL_URL"); then
        sleep 2
        if find_singbox; then
            printf "${GREEN}安装成功！检测到: %s${NC}\n" "$SINGBOX_BIN"
        else
            printf "${YELLOW}安装脚本完成，但未检测到可执行文件。请手动检查。${NC}\n"
        fi
    else
        printf "${RED}安装失败，请检查网络或仓库地址。${NC}\n"
    fi
    read -p "按回车键继续..." dummy
}

# ----------------- 服务控制 -----------------
service_menu() {
    if ! find_singbox; then
        printf "${RED}sing-box 未安装。${NC}\n"
        read -p "按回车键继续..." dummy
        return
    fi
    while true; do
        clear
        printf "${BLUE}====== sing-box 服务管理 ======${NC}\n"
        printf "状态: "; check_status
        echo ""
        echo "1. 启动"
        echo "2. 停止"
        echo "3. 重启"
        echo "4. 查看状态 (详细)"
        echo "5. 查看实时日志"
        echo "0. 返回上级"
        read -p "选择: " c
        case $c in
            1) systemctl start sing-box 2>/dev/null || service sing-box start; sleep 1;;
            2) systemctl stop sing-box 2>/dev/null || service sing-box stop; sleep 1;;
            3) systemctl restart sing-box 2>/dev/null || service sing-box restart; sleep 1;;
            4)
                if command -v systemctl &>/dev/null; then
                    systemctl status sing-box --no-pager 2>/dev/null
                else
                    service sing-box status 2>/dev/null
                fi
                read -p "按回车键继续..." dummy
                ;;
            5) journalctl -u sing-box -f 2>/dev/null || tail -f /var/log/sing-box.log 2>/dev/null || printf "${RED}无日志可显示${NC}\n"; sleep 2;;
            0) break;;
            *) printf "${RED}无效选项${NC}\n"; sleep 1;;
        esac
    done
}

# ----------------- 配置管理 -----------------
config_menu() {
    if ! find_singbox; then
        printf "${RED}sing-box 未安装。${NC}\n"
        read -p "按回车键继续..." dummy
        return
    fi
    local conf="/usr/local/etc/sing-box/config.json"
    if [ ! -f "$conf" ]; then
        conf="/etc/sing-box/config.json"
    fi

    while true; do
        clear
        printf "${BLUE}====== sing-box 配置管理 ======${NC}\n"
        echo "配置文件: $conf"
        echo "1. 查看配置"
        echo "2. 编辑配置 (nano)"
        echo "3. 校验配置语法"
        echo "0. 返回上级"
        read -p "选择: " c
        case $c in
            1)
                [ -f "$conf" ] && cat "$conf" || printf "${RED}文件不存在${NC}\n"
                read -p "按回车键继续..." dummy
                ;;
            2)
                [ -f "$conf" ] && nano "$conf" || printf "${RED}文件不存在${NC}\n"
                ;;
            3)
                if [ -f "$conf" ]; then
                    "$SINGBOX_BIN" check -c "$conf" 2>&1 && printf "${GREEN}配置正确${NC}\n" || printf "${RED}配置有误${NC}\n"
                else
                    printf "${RED}文件不存在${NC}\n"
                fi
                read -p "按回车键继续..." dummy
                ;;
            0) break;;
            *) printf "${RED}无效选项${NC}\n"; sleep 1;;
        esac
    done
}

# ----------------- 主菜单 -----------------
while true; do
    clear
    printf "${BLUE}========== sing-box 管理 ==========${NC}\n"
    printf "状态: "; check_status
    printf "\n"
    echo "1. 安装 / 重新安装"
    echo "2. 服务管理"
    echo "3. 配置管理"
    echo "0. 返回主菜单"
    read -p "选择: " main_choice

    case $main_choice in
        1) do_install ;;
        2) service_menu ;;
        3) config_menu ;;
        0) break ;;
        *) printf "${RED}无效选项${NC}\n"; sleep 1 ;;
    esac
done