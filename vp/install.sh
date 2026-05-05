#!/bin/bash
# 一键部署 VPS 管理面板 (vp)

REPO_URL="https://raw.githubusercontent.com/lje02/liang/main/vp"
INSTALL_DIR="/usr/local/bin"
MODULES_DIR="/usr/local/share/vp_modules"

set -e

mkdir -p "$MODULES_DIR"

echo "下载公共库..."
curl -sSL "$REPO_URL/common.sh" -o "$MODULES_DIR/common.sh"

echo "下载主控脚本..."
curl -sSL "$REPO_URL/vp" -o "$INSTALL_DIR/vp"
chmod +x "$INSTALL_DIR/vp"

echo "下载模块..."
for mod in firewall_fail2ban system_optimize remote_jump singbox; do
    curl -sSL "$REPO_URL/modules/${mod}.sh" -o "$MODULES_DIR/${mod}.sh"
    chmod +x "$MODULES_DIR/${mod}.sh"
done

echo ""
echo "安装完成！输入 'vp' 即可启动管理面板。"
