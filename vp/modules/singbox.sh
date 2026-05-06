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

install_singbox() {
    printf "${BLUE}正在安装 sing-box 脚本...${NC}\n"
    local tmp_install="/tmp/singbox_install.sh"
    curl -sSL "$SINGBOX_INSTALL_URL" -o "$tmp_install"

    if [ ! -s "$tmp_install" ]; then
        printf "${RED}下载安装脚本失败，请检查网络。${NC}\n"
        read -p "按回车键继续..." dummy
        return 1
    fi

    chmod +x "$tmp_install"

    if bash "$tmp_install"; then
        printf "${GREEN}sing-box 安装完成！${NC}\n"

        sleep 1
        hash -r 2>/dev/null

        if ! command -v ssb &>/dev/null; then
            printf "${YELLOW}ssb 命令未自动创建，尝试手动修复...${NC}\n"
            if [ -f "$tmp_install" ]; then
                cp "$tmp_install" /usr/local/bin/ssb
                chmod +x /usr/local/bin/ssb
            else
                curl -sSL "$SINGBOX_INSTALL_URL" -o /usr/local/bin/ssb
                chmod +x /usr/local/bin/ssb
            fi
        fi

        rm -f "$tmp_install"
        printf "${GREEN}ssb 已就绪。${NC}\n"
    else
        printf "${RED}安装失败。${NC}\n"
        rm -f "$tmp_install"
    fi
    read -p "按回车键继续..." dummy
}

enter_singbox() {
    if command -v ssb &>/dev/null; then
        printf "${GREEN}正在进入 sing-box 管理界面...${NC}\n"
        sleep 1
        
        # ssb 即使 exit 也不终止脚本
        ssb || true
        
        echo ""
        printf "${YELLOW}sing-box 面板已退出。${NC}\n"
        read -p "按回车键返回主菜单..." dummy
    else
        printf "${RED}ssb 命令不存在，请先执行选项 1 安装。${NC}\n"
        read -p "按回车键继续..." dummy
    fi
}

while true; do
    clear
    printf "${BLUE}===== sing-box 安装/管理 =====${NC}\n"
    if command -v ssb &>/dev/null; then
        printf "ssb 状态: ${GREEN}可用${NC}\n"
    else
        printf "ssb 状态: ${RED}未安装${NC}\n"
    fi
    echo ""
    echo "1. 安装 sing-box 脚本"
    echo "2. 管理sing-box"
    echo "0. 返回主菜单"
    read -p "请选择: " choice

    case $choice in
        1) install_singbox ;;
        2) enter_singbox ;;
        0) break ;;
        *) printf "${RED}无效选项${NC}\n"; sleep 1 ;;
    esac
done