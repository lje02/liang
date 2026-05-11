#!/bin/bash
# sing-box 管理模块（遵循原安装脚本自部署逻辑）

if [ -z "$VPS_COMMON_LOADED" ]; then
    source /usr/local/share/vp_modules/common.sh 2>/dev/null || {
        echo "无法加载公共函数库"
        exit 1
    }
fi

detect_os
check_dependencies

# 判断 ssb 是否就绪
ssb_available() { command -v ssb &>/dev/null; }

# 安装函数（模拟原始安装脚本的自复制机制）
install_singbox() {
    printf "${BLUE}正在安装 sing-box...${NC}\n"
    local tmp_install="/tmp/singbox_install.sh"

    # 下载安装脚本到临时位置（非目标路径）
    if curl -Ls "$SINGBOX_INSTALL_URL" -o "$tmp_install"; then
        chmod +x "$tmp_install"
        # 执行脚本，此时 $0 是 /tmp/singbox_install.sh ≠ /usr/local/bin/ssb
        # 原脚本内部的 if 判断将触发 cp 操作，自动部署 ssb
        bash "$tmp_install"
        rm -f "$tmp_install"
        hash -r 2>/dev/null

        if ssb_available; then
            printf "${GREEN}安装完成！ssb 命令已就绪。${NC}\n"
        else
            printf "${YELLOW}安装脚本执行完毕，尝试手动激活 ssb...${NC}\n"
            [ -f /usr/local/bin/ssb ] && chmod +x /usr/local/bin/ssb && hash -r
            if ssb_available; then
                printf "${GREEN}ssb 激活成功。${NC}\n"
            else
                printf "${RED}无法激活 ssb，请检查安装脚本。${NC}\n"
            fi
        fi
    else
        printf "${RED}下载安装脚本失败，请检查网络。${NC}\n"
    fi
    read -p "按回车键继续..." dummy
}

# 进入 sing-box 面板
enter_singbox() {
    printf "${GREEN}正在进入 sing-box 管理界面...${NC}\n"
    sleep 1
    ssb || true
    echo ""
    printf "${YELLOW}ssb 已退出。${NC}\n"
    read -p "按回车键返回主菜单..." dummy
}

# ----- 主逻辑：一键直达 -----
if ssb_available; then
    enter_singbox
else
    printf "${YELLOW}未检测到 ssb，正在自动安装...${NC}\n"
    install_singbox
    if ssb_available; then
        enter_singbox
    else
        printf "${RED}安装失败，无法进入 sing-box 面板。${NC}\n"
        read -p "按回车键返回主菜单..." dummy
    fi
fi