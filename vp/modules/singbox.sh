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

# ssb 函数：调用系统 ssb 命令或提示安装
ssb() {
    if command -v ssb &>/dev/null; then
        # 系统 ssb 存在，直接调用
        /usr/bin/env ssb "$@"
        return $?
    elif command -v sing-box &>/dev/null; then
        # sing-box 已装但 ssb 缺失
        printf "${YELLOW}sing-box 已安装，但未找到 ssb 管理面板。${NC}\n"
        printf "你可以手动管理，或重新安装获取 ssb。\n"
        return 1
    else
        # 都没装
        printf "${RED}sing-box 未安装，请先安装。${NC}\n"
        return 1
    fi
}

# 主逻辑
if command -v ssb &>/dev/null; then
    # ssb 存在，直接进入交互面板
    ssb
    echo ""
    read -p "ssb 已退出，按回车键返回主菜单..." dummy
elif command -v sing-box &>/dev/null; then
    # sing-box 有但 ssb 无，提示
    printf "${YELLOW}sing-box 已安装，但未找到 ssb 管理面板。${NC}\n"
    read -p "是否重新安装以获取 ssb？[y/N]: " reinstall
    if [[ $reinstall =~ ^[Yy]$ ]]; then
        bash <(curl -sSL "$SINGBOX_INSTALL_URL") || {
            printf "${RED}安装失败${NC}\n"
            read -p "按回车键返回..." dummy
        }
        if command -v ssb &>/dev/null; then
            ssb
            echo ""
            read -p "ssb 已退出，按回车键返回主菜单..." dummy
        fi
    fi
else
    # 都没装
    printf "${YELLOW}sing-box 未安装。${NC}\n"
    read -p "是否现在安装？[Y/n]: " confirm
    if [[ $confirm =~ ^[Yy]?$ ]]; then
        bash <(curl -sSL "$SINGBOX_INSTALL_URL") || {
            printf "${RED}安装失败，请检查网络。${NC}\n"
            read -p "按回车键返回..." dummy
        }
        if command -v ssb &>/dev/null; then
            ssb
            echo ""
            read -p "ssb 已退出，按回车键返回主菜单..." dummy
        fi
    fi
fi