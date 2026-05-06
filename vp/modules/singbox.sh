#!/bin/bash
# sing-box 管理模块（直接调用 ssb 面板）

if [ -z "$VPS_COMMON_LOADED" ]; then
    source /usr/local/share/vp_modules/common.sh 2>/dev/null || {
        echo "无法加载公共函数库"
        exit 1
    }
fi

detect_os
check_dependencies

if command -v ssb &>/dev/null; then
    ssb
    echo ""
    read -p "ssb 已退出，按回车键返回..." dummy
elif command -v sing-box &>/dev/null; then
    # sing-box 已安装但 ssb 命令缺失
    printf "${YELLOW}sing-box 已安装，但未找到 ssb 管理面板。${NC}\n"
    printf "你可以手动管理 sing-box：\n"
    echo "  配置: /usr/local/etc/sing-box/config.json"
    echo "  启动: systemctl start sing-box"
    echo "  状态: systemctl status sing-box"
    echo ""
    read -p "是否重新安装以获取 ssb 面板？[y/N]: " reinstall
    if [[ $reinstall =~ ^[Yy]$ ]]; then
        bash <(curl -sSL "$SINGBOX_INSTALL_URL") || {
            printf "${RED}安装失败${NC}\n"
        }
    fi
    read -p "按回车键返回..." dummy
else
    printf "${YELLOW}sing-box 未安装。${NC}\n"
    read -p "是否现在安装？[Y/n]: " confirm
    if [[ $confirm =~ ^[Yy]?$ ]]; then
        bash <(curl -sSL "$SINGBOX_INSTALL_URL") || {
            printf "${RED}安装失败，请检查网络。${NC}\n"
        }
        if command -v ssb &>/dev/null; then
            ssb
            echo ""
            read -p "ssb 已退出，按回车键返回..." dummy
        fi
    fi
fi