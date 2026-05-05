#!/bin/bash
# 模块：系统信息与优化

if [ -z "$VPS_COMMON_LOADED" ]; then
    source /usr/local/share/vps_modules/common.sh 2>/dev/null || {
        echo "无法加载公共函数库"
        exit 1
    fi
}

show_system_info() {
    # …… 保持原样（已包含网络信息） ……
}

install_bbr() {
    # …… 保持原样 ……
}

config_swap() {
    # …… 保持原样 ……
}

system_opt_menu() {
    while true; do
        clear
        printf "${BLUE}===== 系统信息与优化 =====${NC}\n"
        echo "1. 查看系统与网络信息"
        echo "2. 安装/开启 BBR"
        echo "3. 虚拟内存配置 (Swap)"
        echo "0. 返回上级菜单"
        read -p "请选择: " opt_choice
        case $opt_choice in
            1) show_system_info ;;
            2) install_bbr ;;
            3) config_swap ;;
            0) break ;;
            *) printf "${RED}无效选项${NC}\n" ;;
        esac
    done
}

system_opt_menu