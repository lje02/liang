#!/bin/bash
# sing-box 安装模块

if [ -z "$VPS_COMMON_LOADED" ]; then
    source /usr/local/share/vp_modules/common.sh 2>/dev/null || true
fi

install_singbox() {
    local tmp_install="/tmp/singbox_install.sh"
    printf "${BLUE}▶ 正在下载原始安装脚本...${NC}\n"
    if curl -Ls "$SINGBOX_INSTALL_URL" -o "$tmp_install"; then
        chmod +x "$tmp_install"
        printf "${BLUE}▶ 开始安装 sing-box ...${NC}\n"
        if bash "$tmp_install"; then
            rm -f "$tmp_install"
            hash -r 2>/dev/null
            printf "${GREEN}✔ 安装完成，ssb 命令已就绪。${NC}\n"
        else
            rm -f "$tmp_install"
            printf "${RED}✖ 安装过程出错。${NC}\n"
        fi
    else
        printf "${RED}✖ 下载失败，请检查网络。${NC}\n"
    fi
}

install_singbox
echo ""
read -p "按回车键返回主菜单..." dummy