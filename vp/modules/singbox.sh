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

# 检查 ssb 命令是否存在
ssb_exists() {
    command -v ssb &>/dev/null
}

# 安装 sing-box 脚本
install_singbox() {
    printf "${BLUE}正在安装 sing-box 脚本...${NC}\n"
    if bash <(curl -sSL "$SINGBOX_INSTALL_URL"); then
        printf "${GREEN}安装成功！${NC}\n"
    else
        printf "${RED}安装失败，请检查网络。${NC}\n"
    fi
    read -p "按回车键继续..." dummy
}

# 进入 sing-box 管理界面
enter_singbox() {
    if ssb_exists; then
        printf "${GREEN}正在进入 sing-box 管理界面...${NC}\n"
        sleep 1
        ssb
        echo ""
        read -p "ssb 已退出，按回车键返回..." dummy
    else
        printf "${RED}ssb 命令不存在，请先执行选项 1 安装。${NC}\n"
        read -p "按回车键继续..." dummy
    fi
}

# 主菜单
while true; do
    clear
    printf "${BLUE}===== sing-box 安装/管理 =====${NC}\n"
    if ssb_exists; then
        printf "ssb 状态: ${GREEN}可用${NC}\n"
    else
        printf "ssb 状态: ${RED}未安装${NC}\n"
    fi
    echo ""
    echo "1. 安装 sing-box 脚本"
    echo "2. 进入 (调用 ssb 命令)"
    echo "0. 返回主菜单"
    read -p "请选择: " choice

    case $choice in
        1) install_singbox ;;
        2) enter_singbox ;;
        0) break ;;
        *) printf "${RED}无效选项${NC}\n"; sleep 1 ;;
    esac
done