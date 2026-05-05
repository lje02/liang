#!/bin/bash
# 一键安装 VPS 管理面板 (vp)
set -e

REPO_URL="https://raw.githubusercontent.com/lje02/liang/main"
INSTALL_DIR="/usr/local/bin"
MODULES_DIR="/usr/local/share/vp_modules"

mkdir -p "$MODULES_DIR"

# 下载公共库
curl -sSL "$REPO_URL/common.sh" -o "$MODULES_DIR/common.sh"

# 下载主控脚本
curl -sSL "$REPO_URL/vp" -o "$INSTALL_DIR/vp"
chmod +x "$INSTALL_DIR/vp"

# 下载模块
for mod in firewall_fail2ban system_optimize remote_jump singbox; do
    curl -sSL "$REPO_URL/modules/${mod}.sh" -o "$MODULES_DIR/${mod}.sh"
    chmod +x "$MODULES_DIR/${mod}.sh"
done

echo "安装完成！现在输入 'vp' 启动面板。"
