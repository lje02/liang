#!/usr/bin/env bash
# ============================================================
# wp-deploy.sh 安全加固补丁 - 版本 B 密码生成
# 
# 修复内容：
#   1. 密码生成增强（16→24字符，94→140 bits熵）
#   2. 字符集优化（移除混淆字符）
#   3. 凭证显示安全化
#   4. 临时文件安全删除
#
# 应用方式：
#   1. 复制本文件中的函数到 wp-deploy.sh
#   2. 替换原有的 _gen_salt 和密码生成逻辑
#   3. 测试后上线
# ============================================================

# ════════════════════════════════════════════════════════
# 核心函数：版本 B 密码生成（生产级强度）
# ════════════════════════════════════════════════════════

_secure_gen_password() {
    # ✅ 版本 B：24 字符，64 字符集，~140 bits 熵
    # 
    # 字符集设计：
    #   - 移除 0/O 混淆（防止用户读错）
    #   - 移除 1/l/I 混淆
    #   - 移除 shell 元字符（| ; < > [ ] { } ）
    #   - 保留数字 + 大小写 + 安全特殊字符
    #
    # 字符集: 2-9, A-Z (无 O/I), a-z (无 l/o), 特殊字符
    local CHARSET="23456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghjkmnpqrstuvwxyz!@#%^&*-_=+"
    
    # 长度: 24 字符（比原来的 16 增加 50%）
    # 熵计算: 24 * log₂(64) = 144 bits（对标 AWS/Google 标准）
    LC_ALL=C tr -dc "$CHARSET" < /dev/urandom 2>/dev/null | head -c 24
    
    # 返回状态检查
    if [[ ${PIPESTATUS[0]} -ne 0 ]]; then
        error "_secure_gen_password: /dev/urandom 读取失败"
        return 1
    fi
}

# ════════════════════════════════════════════════════════
# WordPress Salts 生成（保持原强度但改进字符集）
# ════════════════════════════════════════════════════════

_gen_salt() {
    # ✅ 64 字符，包含完整字符集（用于 WordPress Salts）
    # Salts 在 PHP 中��析，不需要担心 shell 问题
    # 因此可以使用完整的字符集
    local CHARSET="ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789!@#$%^&*()_+-=[]{}|;:,.<>?"
    
    LC_ALL=C tr -dc "$CHARSET" < /dev/urandom 2>/dev/null | head -c 64
    
    if [[ ${PIPESTATUS[0]} -ne 0 ]]; then
        error "_gen_salt: /dev/urandom 读取失败"
        return 1
    fi
}

# ════════════════════════════════════════════════════════
# 安全显示凭证（版本 A 方案 1）
# ════════════════════════════════════════════════════════

_display_credentials_onetime() {
    local ADMIN="$1" PASS="$2" URL="$3" EMAIL="$4"
    
    # 创建临时文件（自动清除）
    local CRED_FILE="/tmp/wp-cred-$(date +%s%N).txt"
    trap "shred -vfz '$CRED_FILE' 2>/dev/null; rm -f '$CRED_FILE'" RETURN EXIT
    
    # 写入临时文件（权限 600）
    cat > "$CRED_FILE" <<EOF
╔══════════════════════════════════════════════════════════════════╗
║             WordPress 管理员凭证（一次性显示）                  ║
╚══════════════════════════════════════════════════════════════════╝

🔐 账户信息：
   用户名:     $ADMIN
   密码:       $PASS
   邮箱:       $EMAIL

🌐 访问地址：
   登录页:     $URL/wp-login.php
   后台:       $URL/wp-admin/

⚠️  重要提示：
   ✓ 此密码仅显示此一次
   ✓ 请立即复制并妥善保管（可保存到密码管理器）
   ✓ 生成时间: $(date -Iseconds)
   ✓ 按回车后文件将被安全删除（shred 覆写）

💡 建议：
   1. 按 Ctrl+A 全选，Ctrl+C 复制
   2. 打开密码管理器（1Password / Bitwarden / KeePass）
   3. 粘贴保存
   4. 按回车继续

════════════════════════════════════════════════════════════════════
EOF
    
    chmod 600 "$CRED_FILE"
    
    # 显示（通过 cat 而非 echo，避免 shell 扩展）
    cat "$CRED_FILE"
    
    # 等待用户确认
    echo ""
    read -rp "✓ 已复制凭证？按回车继续（文件将被安全删除）..." || true
    
    log "凭证文件已通过 shred 安全删除"
}

# ════════════════════════════════════════════════════════
# 选项 B：加密保存凭证（用于 CI/CD）
# ════════════════════════════════════════════════════════

_save_credentials_encrypted() {
    local INST="$1" ADMIN="$2" PASS="$3" URL="$4" EMAIL="$5"
    
    local CRED_DIR="$HOME/.wp-credentials"
    mkdir -p "$CRED_DIR"
    chmod 700 "$CRED_DIR"
    
    # 检查 GPG
    if ! command -v gpg &>/dev/null; then
        warn "GPG 未安装，使用非加密保存"
        cat > "${CRED_DIR}/${INST}-admin.txt" <<EOF
[$(date -Iseconds)] WordPress Credentials for $INST

Username: $ADMIN
Password: $PASS
Email: $EMAIL
Login URL: $URL/wp-login.php

⚠️  This file contains sensitive information!
    Please ensure proper access controls (chmod 600).
EOF
        chmod 600 "${CRED_DIR}/${INST}-admin.txt"
        warn "⚠️  凭证已保存（未加密）: ${CRED_DIR}/${INST}-admin.txt"
        return
    fi
    
    # 使用 GPG 加密
    info "使用 GPG 加密保存凭证..."
    
    cat <<EOF | gpg --symmetric --cipher-algo AES256 \
                      --batch --yes \
                      --output "${CRED_DIR}/${INST}-admin.txt.gpg"
[Generated: $(date -Iseconds)]
WordPress Instance: $INST

Username: $ADMIN
Password: $PASS
Email: $EMAIL
Login URL: $URL/wp-login.php

========================================
Decryption Command:
  gpg -d ~/.wp-credentials/${INST}-admin.txt.gpg

Update Password in WordPress:
  wp user update $ADMIN --prompt=user_pass
========================================
EOF
    
    if [[ $? -eq 0 ]]; then
        chmod 600 "${CRED_DIR}/${INST}-admin.txt.gpg"
        log "✓ 凭证已 GPG 加密保存"
        log "查看命令: gpg -d ~/.wp-credentials/${INST}-admin.txt.gpg"
        log "首次查看需要输入 GPG 密码"
    else
        error "GPG 加密失败"
    fi
}

# ════════════════════════════════════════════════════════
# 修改：_setup_plugins 函数集成
# ════════════════════════════════════════════════════════

_setup_plugins_secure() {
    local DIR="$1"
    local IS_AUTO_INSTALL="${2:-false}"
    local URL="${3:-}"
    local TITLE="${4:-}"
    local ADMIN="${5:-}"
    local PASS="${6:-}"
    local EMAIL="${7:-}"
    local LOCALE="${8:-zh_CN}"
    local MS_TYPE="${9:-}"
    local MS_DOMAIN="${10:-}"
    
    info "等待 WordPress 容器就绪..."
    local RETRIES=30
    local -a WP_CMD
    
    if docker compose version &>/dev/null 2>&1; then
        WP_CMD=(docker compose -f "$DIR/docker-compose.yml" --env-file "$DIR/.env"
                exec -T wordpress wp --allow-root)
    else
        WP_CMD=(docker-compose -f "$DIR/docker-compose.yml" --env-file "$DIR/.env"
                exec -T wordpress wp --allow-root)
    fi
    
    while ! "${WP_CMD[@]}" cli version &>/dev/null; do
        sleep 3
        RETRIES=$((RETRIES - 1))
        [[ $RETRIES -le 0 ]] && { warn "容器未就绪，中止插件配置。"; return 1; }
    done
    
    # 检查 wp-config.php
    if ! docker compose -f "$DIR/docker-compose.yml" --env-file "$DIR/.env" \
         exec -T wordpress test -s /var/www/html/wp-config.php; then
        info "创建 wp-config.php ..."
        local DB_NAME DB_USER DB_PW DB_HOST
        DB_NAME=$(env_get "$DIR/.env" "WORDPRESS_DB_NAME")
        DB_USER=$(env_get "$DIR/.env" "WORDPRESS_DB_USER")
        DB_PW=$(env_get "$DIR/.env" "WORDPRESS_DB_PASSWORD")
        DB_HOST=$(env_get "$DIR/.env" "DB_HOST")
        
        _wp_config_create_with_extra "$DIR" "$DB_NAME" "$DB_USER" "$DB_PW" "$DB_HOST" \
            || { warn "wp-config.php 创建失败，请检查数据库连接。"; return 1; }
        log "wp-config.php 已自动生成。"
        
        local _CID_FOR_CFG
        _CID_FOR_CFG=$(docker compose -f "$DIR/docker-compose.yml" --env-file "$DIR/.env" ps -q wordpress 2>/dev/null)
        if [[ -n "$_CID_FOR_CFG" ]]; then
            docker compose -f "$DIR/docker-compose.yml" --env-file "$DIR/.env" \
                exec -T wordpress cp /var/www/html/wp-config.php /tmp/wp-config-out.php \
            && docker cp "${_CID_FOR_CFG}:/tmp/wp-config-out.php" "$DIR/conf/wp-config.php" \
            && log "wp-config.php 已落盘到 ${DIR}/conf/" \
            || warn "wp-config.php 落盘失败"
        fi
    fi
    
    # 🆕 安装逻辑：使用版本 B 密码
    if [[ "$IS_AUTO_INSTALL" == "true" ]]; then
        if ! "${WP_CMD[@]}" core is-installed &>/dev/null; then
            info "安装 WordPress 核心..."
            
            # ✅ 使用版本 B 生成的强密码
            local ADMIN_PASS
            ADMIN_PASS=$(_secure_gen_password)
            
            "${WP_CMD[@]}" core install \
                --url="$URL" --title="$TITLE" \
                --admin_user="$ADMIN" \
                --admin_email="$EMAIL" \
                --admin_password="$ADMIN_PASS" \
                --locale="$LOCALE" --skip-email \
            || { warn "安装失败，请查看日志。"; return 1; }
            
            log "WordPress 安装成功！"
            
            # ✅ 显示凭证（方案 1）
            _display_credentials_onetime "$ADMIN" "$ADMIN_PASS" "$URL" "$EMAIL"
            
            # ✅ 可选：加密保存（方案 B，���对 CI/CD）
            if [[ "${SAVE_WP_CREDENTIALS:-false}" == "true" ]]; then
                local INST
                INST=$(env_get "$DIR/.env" "WP_INSTANCE" 2>/dev/null || echo "wordpress")
                _save_credentials_encrypted "$INST" "$ADMIN" "$ADMIN_PASS" "$URL" "$EMAIL"
            fi
            
            # ✅ 清空密码变量
            ADMIN_PASS=""
            unset ADMIN_PASS
            
            echo ""
            _c "1;33" ">>> WP-Cron 定时任务提示 <<<"
            echo -e "  内置 WP-Cron 已禁用，请在\e[33m某一台节点宿主机\e[0m添加以下 crontab："
            echo -e "  \e[36m*/5 * * * * docker exec \$(docker ps -qf name=wordpress) wp --allow-root cron event run --due-now --path=/var/www/html >/dev/null 2>&1\e[0m"
        else
            log "数据库已有数据，跳过安装。"
        fi
    fi
    
    # 后续配置...（保持原样）
}

# ════════════════════════════════════════════════════════
# 实用工具函数
# ════════════════════════════════════════════════════════

# 验证密码强度
_verify_password_strength() {
    local pass="$1"
    local len=${#pass}
    local entropy_approx=$(( len * 6 ))  # log₂(64) ≈ 6
    
    echo "密码强度分析："
    echo "  长度: $len 字符"
    echo "  估计熵: ~$entropy_approx bits"
    
    if (( len >= 24 && entropy_approx >= 140 )); then
        echo "  级别: ✅ 强（生产级）"
    elif (( len >= 16 && entropy_approx >= 96 )); then
        echo "  级别: ⚠️  中等"
    else
        echo "  级别: ❌ 弱"
    fi
}

# 批量生成 N 个密码（测试用）
_generate_passwords_batch() {
    local count="${1:-10}"
    
    echo "生成 $count 个版本 B 密码："
    echo "=========================================="
    
    for ((i=1; i<=count; i++)); do
        local pass
        pass=$(_secure_gen_password)
        printf "%2d. %s (len=%d)\n" "$i" "$pass" "${#pass}"
    done
    
    echo "=========================================="
}

# 检查系统环境是否满足要求
_check_password_requirements() {
    echo "检查密码生成环境..."
    
    # 检查 /dev/urandom
    if [[ ! -r /dev/urandom ]]; then
        error "/dev/urandom 不可读"
    fi
    info "✓ /dev/urandom 可用"
    
    # 检查 tr 命令
    if ! command -v tr &>/dev/null; then
        error "tr 命令不可用"
    fi
    info "✓ tr 命令可用"
    
    # 检查 shred 命令（可选但推荐）
    if command -v shred &>/dev/null; then
        info "✓ shred 命令可用（安全删除）"
    else
        warn "⚠️  shred 命令不可用（推荐安装以实现安全删除）"
        warn "   在 Linux 上：apt install coreutils  或  yum install coreutils"
    fi
    
    # 检查 GPG 命令（可选）
    if command -v gpg &>/dev/null; then
        info "✓ gpg 命令可用（可加密保存凭证）"
    else
        warn "⚠️  gpg 命令不可用（可选，用于加密保存）"
    fi
}

# ════════════════════════════════════════════════════════
# 使用示例 & 测试
# ════════════════════════════════════════════════════════

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    # 直接运行此脚本时执行测试
    
    echo "═══════════════════════════════════════════"
    echo "版本 B 密码生成 - 安全性测试"
    echo "═══════════════════════════════════════════"
    echo ""
    
    _check_password_requirements
    echo ""
    
    echo "单次密码生成测试："
    echo "=========================================="
    pass=$(_secure_gen_password)
    echo "生成的密码: $pass"
    _verify_password_strength "$pass"
    echo "=========================================="
    echo ""
    
    echo "批量生成测试（10 个密码）："
    _generate_passwords_batch 10
    echo ""
    
    echo "✅ 测试完成！"
    echo ""
    echo "集成方法："
    echo "  1. 复制 _secure_gen_password() 到 wp-deploy.sh"
    echo "  2. 替换原有的密码生成逻辑"
    echo "  3. 修改 _setup_plugins 调用 _secure_gen_password"
    echo "  4. 添加 _display_credentials_onetime 函数"
    echo ""
fi
