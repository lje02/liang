#!/bin/bash
# sing-box 管理模块（仅管理，不自动安装）
if [ -z "$VPS_COMMON_LOADED" ]; then
    source /usr/local/share/vp_modules/common.sh 2>/dev/null || {
        echo "无法加载公共函数库"
        exit 1
    }
fi

detect_os
check_dependencies

if command -v ssb &>/dev/null; then
    printf "${GREEN}正在进入 sing-box 管理界面...${NC}\n"
    sleep 1
    ssb || true
    echo ""
    printf "${YELLOW}ssb 已退出。${NC}\n"
    read -p "按回车键返回主菜单..." dummy
else
    printf "${RED}未检测到 ssb 命令，sing-box 未安装或已卸载。${NC}\n"
    printf "请使用主菜单的 “安装/重装 sing-box” 先安装。\n"
    read -p "按回车键返回主菜单..." dummy
fi