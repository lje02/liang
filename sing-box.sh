#!/bin/bash
# 模块：sing-box 管理

if [ -z "$VPS_COMMON_LOADED" ]; then
    source /usr/local/share/vps_modules/common.sh 2>/dev/null || {
        echo "无法加载公共函数库"
        exit 1
    fi
fi

run_singbox_menu() {
    if command -v ssb &>/dev/null; then
        ssb
    else
        printf "${YELLOW}sing-box 管理脚本未安装。${NC}\n"
        echo "你可以手动安装："
        echo "  curl -sSL $SINGBOX_INSTALL_URL | bash"
        read -p "是否现在自动安装并运行？[Y/n]: " confirm
        if [[ $confirm =~ ^[Yy]?$ ]]; then
            bash <(curl -sSL "$SINGBOX_INSTALL_URL") || {
                printf "${RED}sing-box 安装失败，请检查网络或仓库地址。${NC}\n"
                return
            }
            if command -v ssb &>/dev/null; then ssb
            else printf "${RED}安装后未找到 ssb 命令，请手动检查。${NC}\n"; fi
        fi
    fi
}

run_singbox_menu