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

run_singbox_menu() {
    while true; do
        clear
        printf "${BLUE}===== sing-box 管理 =====${NC}\n"
        
        if command -v sing-box &>/dev/null; then
            local version=$(sing-box version 2>/dev/null | head -1)
            printf "状态: ${GREEN}已安装 (%s)${NC}\n\n" "$version"
        elif command -v ssb &>/dev/null; then
            printf "状态: ${GREEN}已安装 (ssb 命令可用)${NC}\n\n"
        else
            printf "状态: ${RED}未安装${NC}\n\n"
        fi

        echo "1. 启动 sing-box 管理面板 (ssb)"
        echo "2. 安装/重新安装 sing-box"
        echo "3. 查看 sing-box 版本信息"
        echo "4. 查看 sing-box 运行状态"
        echo "0. 返回主菜单"
        read -p "请选择: " choice

        case $choice in
            1)
                if command -v ssb &>/dev/null; then
                    printf "${GREEN}正在启动 ssb 面板...${NC}\n"
                    sleep 1
                    ssb
                    echo ""
                    read -p "ssb 已退出，按回车继续..." dummy
                elif command -v sing-box &>/dev/null; then
                    printf "${YELLOW}ssb 命令不存在，但 sing-box 已安装。${NC}\n"
                    printf "你可以手动管理 sing-box：\n"
                    echo "  配置文件: /usr/local/etc/sing-box/config.json"
                    echo "  启动: systemctl start sing-box"
                    echo "  停止: systemctl stop sing-box"
                    echo "  重启: systemctl restart sing-box"
                    echo "  状态: systemctl status sing-box"
                    echo ""
                    read -p "按回车继续..." dummy
                else
                    printf "${RED}sing-box 未安装，请先选择 2 安装。${NC}\n"
                    read -p "按回车继续..." dummy
                fi
                ;;
            2)
                printf "${YELLOW}正在安装/重新安装 sing-box...${NC}\n"
                bash <(curl -sSL "$SINGBOX_INSTALL_URL") || {
                    printf "${RED}安装失败，请检查网络或仓库地址。${NC}\n"
                    read -p "按回车继续..." dummy
                    continue
                }
                if command -v ssb &>/dev/null || command -v sing-box &>/dev/null; then
                    printf "${GREEN}sing-box 安装成功！${NC}\n"
                else
                    printf "${RED}安装后未检测到 sing-box 或 ssb 命令，请手动检查。${NC}\n"
                fi
                read -p "按回车继续..." dummy
                ;;
            3)
                if command -v sing-box &>/dev/null; then
                    printf "${GREEN}sing-box 版本信息:${NC}\n"
                    sing-box version
                else
                    printf "${RED}sing-box 未安装。${NC}\n"
                fi
                echo ""
                read -p "按回车继续..." dummy
                ;;
            4)
                if command -v sing-box &>/dev/null; then
                    printf "${GREEN}sing-box 运行状态:${NC}\n"
                    systemctl status sing-box 2>/dev/null || service sing-box status 2>/dev/null || \
                    ps aux | grep sing-box | grep -v grep
                else
                    printf "${RED}sing-box 未安装。${NC}\n"
                fi
                echo ""
                read -p "按回车继续..." dummy
                ;;
            0) break ;;
            *) 
                printf "${RED}无效选项${NC}\n"
                sleep 1
                ;;
        esac
    done
}

run_singbox_menu