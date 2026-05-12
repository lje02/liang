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

# 从 vp 脚本中提取 MODULES_LIST 数组内容
MAPfile -t modules < <(grep -E '^[[:space:]]*"' "$INSTALL_DIR/vp" | grep -E '\.sh"' | tr -d '[:space:]"')

# 或者用更精确的 sed 提取
# modules=($(sed -n '/^MODULES_LIST=(/,/)/p' "$INSTALL_DIR/vp" | grep '\.sh' | tr -d '" '))

echo "下载模块..."
for mod in "${modules[@]}"; do
    echo "  -> $mod"
    curl -sSL "$REPO_URL/modules/$mod" -o "$MODULES_DIR/$mod" || echo " [失败，跳過]"
    chmod +x "$MODULES_DIR/$mod" 2>/dev/null
done

echo ""
echo "安装完成！输入 'vp' 即可启动管理面板。"
