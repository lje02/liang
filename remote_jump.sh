#!/bin/bash
# 模块：远程SSH跳转

if [ -z "$VPS_COMMON_LOADED" ]; then
    source /usr/local/share/vps_modules/common.sh 2>/dev/null || {
        echo "无法加载公共函数库"
        exit 1
    fi
fi

REMOTE_CONF="/etc/vps_manager_remotes.conf"
[ ! -f "$REMOTE_CONF" ] && touch "$REMOTE_CONF" && chmod 600 "$REMOTE_CONF"

setup_ssh_key() {
    # …… 原函数内容 ……
}

delete_remote_host() {
    # …… 注意：这里删除了对 detect_fail2ban 等无关依赖 ……
}

add_remote_host() {
    # ……
}

remote_jump_menu() {
    # …… 使用索引数组，无 eval ……
}

remote_jump_menu