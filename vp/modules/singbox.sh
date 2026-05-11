#!/bin/bash
# sing-box 管理模块（智能判断）
if [ -z "$VPS_COMMON_LOADED" ]; then
    source /usr/local/share/vp_modules/common.sh 2>/dev/null || {
        echo "无法加载公共函数库"
        exit 1
    }
fi

detect_os
check_dependencies

# 检测 ssb 是否存在
ssb_available() { command -v ssb &>/dev/null; }

# 安装
install_singbox() {
    printf "${BLUE}正在安装 sing-box...${NC}\n"
    if curl -Ls "$SINGBOX_INSTALL_URL" -o /usr/local/bin/ssb; then
        chmod +x /usr/local/bin/ssb
        bash /usr/local/bin/ssb
        hash -r 2>/dev/null
        printf "${GREEN}安装完成！${NC}\n"
    else
        printf "${RED}下载安装脚本失败。${NC}\n"
    fi
    read -p "按回车键继续..." dummy
}

# 进入 sing-box 面板
enter_singbox() {
    printf "${GREEN}正在进入 sing-box 面板...${NC}\n"
    sleep 1
    ssb || true
    echo ""
    read -p "ssb 已退出，按回车键返回主菜单..." dummy
}

# ----- 主逻辑：有 ssb 直接进入，无则自动安装后进入 -----
if ssb_available; then
    enter_singbox
else
    printf "${YELLOW}未检测到 ssb，正在自动安装 sing-box...${NC}\n"
    install_singbox
    if ssb_available; then
        enter_singbox
    else
        printf "${RED}安装失败，无法进入。${NC}\n"
        read -p "按回车键返回主菜单..." dummy
    fi
fi