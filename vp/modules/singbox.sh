#!/bin/bash

if [ -z "$VPS_COMMON_LOADED" ]; then
    source /usr/local/share/vp_modules/common.sh 2>/dev/null || true
fi

if command -v ssb &>/dev/null; then
    printf "${GREEN}正在进入 sing-box 管理界面...${NC}\n"
    sleep 1
    ssb
    echo ""
    #printf "${YELLOW}ssb 已退出。${NC}\n"
    sleep 1
else
    printf "${RED}未安装 sing-box脚本。请先使用菜单中的“安装/重装”功能。${NC}\n"
fi

read -p "按回车键返回主菜单..." dummy