#!/bin/bash

if [ -z "$VPS_COMMON_LOADED" ]; then
    source /usr/local/share/vp_modules/common.sh 2>/dev/null || true
fi

# 脚本名称动态获取
SCRIPT_PATH="$(realpath "$0" 2>/dev/null || readlink -f "$0" 2>/dev/null || echo "$0")"

if [[ "$SCRIPT_PATH" != "/usr/local/bin/ssb" ]]; then
    cp "$SCRIPT_PATH" /usr/local/bin/ssb
    chmod +x /usr/local/bin/ssb
    printf "${GREEN}已复制安装脚本到 /usr/local/bin/ssb${NC}\n"
fi

printf "${BLUE}▶ 开始安装 sing-box ...${NC}\n"
bash /usr/local/bin/ssb

echo ""
printf "${GREEN}安装完成...请从主菜单进入 sing-box 管理。${NC}\n"
read -p "按回车键返回主菜单..." dummy