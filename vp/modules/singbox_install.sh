#!/bin/bash
# sing-box 安装模块

# 尝试加载公共库（用于颜色和路径变量），失败也不终止
if [ -z "$VPS_COMMON_LOADED" ]; then
    source /usr/local/share/vp_modules/common.sh 2>/dev/null || true
fi

SINGBOX_INSTALL_URL="${SINGBOX_INSTALL_URL:-https://raw.githubusercontent.com/lje02/liang/main/install.sh}"

install_singbox() {
    printf "${BLUE}▶ 正在下载并安装 sing-box ...${NC}\n"

    if curl -Ls "$SINGBOX_INSTALL_URL" -o /usr/local/bin/ssb; then
        chmod +x /usr/local/bin/ssb
        if /usr/local/bin/ssb; then
            hash -r 2>/dev/null
            #printf "${GREEN}✔ 安装完成，ssb 已就绪。${NC}\n"
        else
            printf "${RED}✖ 安装脚本执行失败。${NC}\n"
        fi
    else
        printf "${RED}✖ 下载失败，请检查网络是否连通。${NC}\n"
    fi
}

install_singbox
echo ""
read -p "按回车键返回主菜单..." dummy