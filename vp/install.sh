#!/bin/bash
# 一键部署 VPS 管理面板 (vp)

REPO_URL="https://raw.githubusercontent.com/lje02/liang/main/vp"
INSTALL_DIR="/usr/local/bin"
MODULES_DIR="/usr/local/share/vp_modules"

set -e

mkdir -p "$MODULES_DIR"

# 公共库和主控先下载（为了获取模块列表）
curl -sSL "$REPO_URL/common.sh" -o "$MODULES_DIR/common.sh"
curl -sSL "$REPO_URL/vp" -o "$INSTALL_DIR/vp"
chmod +x "$INSTALL_DIR/vp"

BASE_MODULES=(
    "firewall_fail2ban.sh"
    "system_optimize.sh"
    "remote_jump.sh"
    "singbox.sh"
    "singbox_install.sh"
)

# 尝试动态提取
if [ -f "$INSTALL_DIR/vp" ]; then
    modules=($(awk '/^MODULES_LIST=\(/ {flag=1; next} /^\)/ {flag=0} flag {gsub(/"/); print $1}' "$INSTALL_DIR/vp"))
fi

# 若提取为空，使用静态列表
[ ${#modules[@]} -eq 0 ] && modules=("${BASE_MODULES[@]}")

echo "下载模块..."
for mod in "${modules[@]}"; do
    echo "  -> $mod"
    curl -sSL "$REPO_URL/modules/$mod" -o "$MODULES_DIR/$mod" || echo " [失败，跳過]"
    chmod +x "$MODULES_DIR/$mod" 2>/dev/null
done

echo ""
echo "安装完成！输入 'vp' 即可启动管理面板。"
