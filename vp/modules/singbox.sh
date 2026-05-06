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

# ---------- 安装 sing-box ----------
install_singbox() {
    printf "${BLUE}正在安装 sing-box...${NC}\n"

    # 仿照一键安装命令：下载 install.sh 并保存为 ssb
    if curl -Ls "$SINGBOX_INSTALL_URL" -o /usr/local/bin/ssb; then
        chmod +x /usr/local/bin/ssb
        printf "${GREEN}安装脚本已下载为 /usr/local/bin/ssb${NC}\n"

        # 执行安装
        printf "${BLUE}执行安装进程...${NC}\n"
        bash /usr/local/bin/ssb

        # 安装脚本内部会执行 cp "$0" /usr/local/bin/ssb，确保 ssb 存在
        hash -r 2>/dev/null
        if command -v ssb &>/dev/null; then
            printf "${GREEN}安装完成！ssb 命令已就绪。${NC}\n"
        else
            # 手动兜底
            [ -f /usr/local/bin/ssb ] && chmod +x /usr/local/bin/ssb && hash -r
            printf "${YELLOW}安装完成，已尝试激活 ssb。${NC}\n"
        fi
    else
        printf "${RED}下载安装脚本失败，请检查网络。${NC}\n"
    fi
    read -p "按回车键继续..." dummy
}

# ---------- 进入 sing-box 管理界面 ----------
enter_singbox() {
    if command -v ssb &>/dev/null; then
        printf "${GREEN}正在进入 sing-box 管理界面...${NC}\n"
        sleep 1
        ssb || true
        echo ""
        printf "${YELLOW}ssb 已退出。${NC}\n"
        read -p "按回车键返回主菜单..." dummy
    else
        printf "${RED}ssb 命令不存在，请先执行选项 1 安装。${NC}\n"
        read -p "按回车键继续..." dummy
    fi
}

# ---------- 主菜单 ----------
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