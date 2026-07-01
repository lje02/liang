#!/usr/bin/env bash
# ============================================================
# wp-deploy.sh — WordPress 多节点全自动部署
# v6.7
# ============================================================
set -euo pipefail
export LANG=en_US.UTF-8
export LC_ALL=en_US.UTF-8

# 脚本版本与自身路径（用于自更新）
SCRIPT_VERSION="6.8"
SCRIPT_SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"
SCRIPT_GITHUB_RAW="${SCRIPT_GITHUB_RAW:-https://raw.githubusercontent.com/lje02/liang/main/wp-deploy.sh}"

BASE_DIR="${BASE_DIR:-/srv}"
WG_IFACE="${WG_IFACE:-wg0}"
REGISTRY_DIR="${BASE_DIR}/registry"
ALIST_DEFAULT_DIR="${ALIST_DEFAULT_DIR:-/mnt/alist/wp-backups/}"

# 当前操作实例（由 _resolve_instance 填充）
INSTANCE=""
INSTANCE_DIR=""
NODES_FILE=""

_c()     { printf "\e[%sm%s\e[0m\n" "$1" "$2"; }
log()    { _c "32"   "[成功] $*"; }
info()   { _c "36"   "[提示] $*"; }
warn()   { _c "33"   "[警告] $*"; }
error()  { _c "31"   "[错误] $*"; exit 1; }
header() { echo; _c "1;34" "=== $* ==="; }

check_deps() {
    local MISSING=()
    command -v docker  &>/dev/null || MISSING+=("docker")
    command -v rsync   &>/dev/null || MISSING+=("rsync")
    command -v ip      &>/dev/null || MISSING+=("iproute2 (ip)")
    command -v curl    &>/dev/null || MISSING+=("curl")
    command -v jq      &>/dev/null || MISSING+=("jq")

    if ! docker compose version &>/dev/null 2>&1; then
        if ! command -v docker-compose &>/dev/null; then
            MISSING+=("docker-compose (plugin or standalone)")
        else
            warn "检测到 docker-compose v1，建议升级到 Docker Compose v2 plugin"
        fi
    fi

    [[ ${#MISSING[@]} -gt 0 ]] && error "缺少以下依赖，请先安装：${MISSING[*]}"
    docker info &>/dev/null || error "Docker daemon 未运行或当前用户无权限"
}

check_port() {
    local IP="$1" PORT="$2"
    if [[ "$IP" == "0.0.0.0" || "$IP" == "::" ]]; then
        ss -tlnp | awk '{print $4}' | grep -qE ":${PORT}$" && error "端口 ${PORT} 已被占用，请先停止对应服务"
    else
        ss -tlnp | awk '{print $4}' | grep -qE "${IP}:${PORT}$" && error "端口 ${IP}:${PORT} 已被占用，请先停止对应服务"
    fi
}

check_network() {
    local targets=("$@")
    for target in "${targets[@]}"; do
        IFS=: read -r host port <<< "$target"
        if [[ ! "$host" =~ ^[a-zA-Z0-9._-]+$ ]] || [[ ! "$port" =~ ^[0-9]+$ ]]; then
            warn "check_network: 无效地址格式 '$target'，跳过"
            continue
        fi
        if ! timeout 3 bash -c "echo >/dev/tcp/${host}/${port}" 2>/dev/null; then
            warn "无法连接 ${host}:${port}，请检查网络/防火墙"
            return 1
        fi
    done
    return 0
}

get_wg_ip() {
    local IP
    IP=$(ip addr show "${WG_IFACE}" 2>/dev/null \
        | awk '/inet /{gsub(/\/.*/, "", $2); print $2; exit}')
    [[ -n "$IP" ]] || error "无法获取 ${WG_IFACE} IP，请确认 WireGuard 已启动"
    echo "$IP"
}

dc() {
    local DIR="$1"; shift
    if docker compose version &>/dev/null 2>&1; then
        docker compose -f "$DIR/docker-compose.yml" --env-file "$DIR/.env" "$@"
    else
        docker-compose -f "$DIR/docker-compose.yml" --env-file "$DIR/.env" "$@"
    fi
}

read_secret() {
    local PROMPT="$1" VAR_NAME="$2" VALUE=""
    IFS= read -rsp "$PROMPT" VALUE || true
    echo ""   # 静默读取后补换行，保持终端整洁
    VALUE="${VALUE#"${VALUE%%[![:space:]]*}"}"
    VALUE="${VALUE%"${VALUE##*[![:space:]]}"}"
    printf -v "$VAR_NAME" '%s' "$VALUE"
}

env_get() {
    local FILE="$1" KEY="$2"
    # [fix] v6.8: 用 sed 替代 grep|cut|head，保留多行值（首行匹配，值可含换行）
    sed -n "s/^${KEY}=//p" "$FILE" 2>/dev/null | head -1
}

# 幂等写入/更新 .env 中的键值：存在则原地替换，不存在则追加
env_set() {
    local FILE="$1" KEY="$2" VALUE="$3"
    [[ -f "$FILE" ]] || : > "$FILE"
    if grep -q "^${KEY}=" "$FILE" 2>/dev/null; then
        local TMP; TMP=$(mktemp)
        awk -F= -v k="$KEY" -v v="$VALUE" \
            'BEGIN{OFS="="} $1==k{$0=k"="v} {print}' "$FILE" > "$TMP" \
            && mv "$TMP" "$FILE"
    else
        printf '%s=%s\n' "$KEY" "$VALUE" >> "$FILE"
    fi
    chmod 600 "$FILE" 2>/dev/null || true
}

# 本地生成 64 字符随机字符串，不依赖外网
# [fix] v6.7: 补齐长度校验。原来末尾的 "; true" 只是为了吞掉
# head 提前退出导致 tr 收到 SIGPIPE 而产生的"假失败"（这一步是对的，
# 不能去掉，否则 set -euo pipefail 会把脚本杀掉）。但这也让
# /dev/urandom 不可读等极端情况下的"真失败"（空输出）被一并吞掉，
# 调用方拿到空字符串却毫无察觉。这里补一次输出长度检查，不够 64
# 字符直接 error 中止，避免用空/短 salt 生成 wp-config-extra.php。
_gen_salt() {
    local _s
    _s=$(LC_ALL=C tr -dc 'A-Za-z0-9!@#%^&*()-_=+[]|;:,.<>?' \
        < /dev/urandom 2>/dev/null | head -c 64; true)
    [[ ${#_s} -eq 64 ]] || error "_gen_salt: 生成的随机串长度异常（${#_s}/64），请检查 /dev/urandom 是否可读"
    printf '%s' "$_s"
}

# ════════════════════════════════════════════════════════
# 实例管理：选择或创建实例，设置 INSTANCE / INSTANCE_DIR / NODES_FILE
# ════════════════════════════════════════════════════════
_resolve_instance() {
    local -n _dir_ref=$1
    local -n _inst_ref=$2

    local instances=()
    if [[ -d "$BASE_DIR" ]]; then
        while IFS= read -r d; do
            [[ -f "$d/.env" ]] && instances+=("$(basename "$d")")
        done < <(find "$BASE_DIR" -maxdepth 1 -mindepth 1 -type d 2>/dev/null | sort)
    fi

    if [[ ${#instances[@]} -gt 0 ]]; then
        echo ""
        echo "已有实例："
        local i=1
        for inst in "${instances[@]}"; do
            echo "  ${i}. ${inst}"
            i=$((i+1))
        done
        echo "  n. 新建实例"
        read -rp "选择实例编号或输入新实例名 [默认: 1]: " _sel || true
        _sel="${_sel:-1}"
        if [[ "$_sel" == "n" || ! "$_sel" =~ ^[0-9]+$ ]]; then
            local _new="$_sel"
            [[ "$_sel" == "n" ]] && { read -rp "新实例名（字母/数字/下划线）: " _new || true; }
            [[ "$_new" =~ ^[a-zA-Z0-9_-]+$ ]] || error "实例名只允许字母、数字、下划线、连字符"
            _inst_ref="$_new"
        else
            _inst_ref="${instances[$((_sel-1))]}"
            [[ -n "$_inst_ref" ]] || error "无效选择"
        fi
    else
        read -rp "实例名 [默认: wordpress]: " _inst_ref || true
        _inst_ref="${_inst_ref:-wordpress}"
        [[ "$_inst_ref" =~ ^[a-zA-Z0-9_-]+$ ]] || error "实例名只允许字母、数字、下划线、连字符"
    fi

    _dir_ref="${BASE_DIR}/${_inst_ref}"
    # 同步更新全局实例变量
    INSTANCE="$_inst_ref"
    INSTANCE_DIR="$_dir_ref"
    NODES_FILE="${_dir_ref}/nodes.conf"
}

_register_node() {
    local IP="$1"
    if [[ ! "$IP" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
        error "_register_node: 无效 IP 格式：${IP}"
    fi
    [[ -n "$NODES_FILE" ]] || error "_register_node: NODES_FILE 未设置，请先调用 _resolve_instance"
    touch "$NODES_FILE"
    if ! grep -qxF "$IP" "$NODES_FILE"; then
        [[ -s "$NODES_FILE" && "$(tail -c1 "$NODES_FILE")" != "" ]] && echo "" >> "$NODES_FILE"
        echo "$IP" >> "$NODES_FILE"
        log "节点 ${IP} 已注册到 ${NODES_FILE}"
    fi
}

# 确保 Docker daemon 信任指定仓库（HTTP）
# 用法: _ensure_insecure_registry <registry_host:port>
_ensure_insecure_registry() {
    local REGISTRY_ADDR="$1"
    local DAEMON_FILE="/etc/docker/daemon.json"

    # 检查 Docker info 是否已经包含该地址
    if docker info 2>/dev/null | grep -qF "$REGISTRY_ADDR"; then
        return 0
    fi

    info "Docker 未信任 ${REGISTRY_ADDR}，正在自动配置..."

    # 备份原文件（如果存在）
    if [[ -f "$DAEMON_FILE" ]]; then
        cp "$DAEMON_FILE" "${DAEMON_FILE}.bak.$(date +%Y%m%d%H%M%S)"
    fi

    # 构造或更新 daemon.json
    if [[ -f "$DAEMON_FILE" ]]; then
        # 文件已存在，用 jq 追加
        local tmp_json
        tmp_json=$(mktemp)
        jq --arg addr "$REGISTRY_ADDR" \
            '.["insecure-registries"] = (.["insecure-registries"] + [$addr] | unique)' \
            "$DAEMON_FILE" > "$tmp_json" \
            && mv "$tmp_json" "$DAEMON_FILE"
    else
        # 文件不存在，直接创建
        printf '{\n  "insecure-registries": ["%s"]\n}\n' "$REGISTRY_ADDR" > "$DAEMON_FILE"
    fi

    # 重启 Docker
    if systemctl restart docker &>/dev/null; then
        log "Docker 已重启，insecure-registries 配置生效。"
    else
        warn "Docker 重启失败，请手动执行: systemctl restart docker"
        return 1
    fi
}

# ════════════════════════════════════════════════════════
# 配置文件生成函数
# ════════════════════════════════════════════════════════

_write_supervisord_conf() { cat > "$1" <<'CONF'
[supervisord]
nodaemon=true
user=root
logfile=/var/log/supervisor/supervisord.log
logfile_maxbytes=10MB
pidfile=/var/run/supervisord.pid

[program:php-fpm]
command=/usr/local/sbin/php-fpm --nodaemonize
autostart=true
autorestart=true
priority=10
stdout_logfile=/dev/stdout
stdout_logfile_maxbytes=0
stderr_logfile=/dev/stderr
stderr_logfile_maxbytes=0

[program:nginx]
command=/usr/sbin/nginx -g "daemon off;"
autostart=true
autorestart=true
priority=20
stdout_logfile=/dev/stdout
stdout_logfile_maxbytes=0
stderr_logfile=/dev/stderr
stderr_logfile_maxbytes=0
CONF
}

_write_nginx_main_conf() { cat > "$1" <<'CONF'
user www-data;
worker_processes auto;
error_log /var/log/nginx/error.log warn;
pid /run/nginx/nginx.pid;

events {
    worker_connections 1024;
    multi_accept on;
}

http {
    include       /etc/nginx/mime.types;
    default_type  application/octet-stream;

    log_format  main  '$remote_addr - $remote_user [$time_local] "$request" '
                      '$status $body_bytes_sent "$http_referer" '
                      '"$http_user_agent" "$http_x_forwarded_for"';
    access_log  /var/log/nginx/access.log  main;

    sendfile           on;
    tcp_nopush         on;
    tcp_nodelay        on;
    keepalive_timeout  65;
    server_tokens      off;

    gzip on;
    gzip_vary on;
    gzip_proxied any;
    gzip_comp_level 6;
    gzip_types text/plain text/css application/json
               application/javascript text/xml application/xml
               application/xml+rss text/javascript image/svg+xml;

    include /etc/nginx/http.d/*.conf;
}
CONF
}

# v6.0: 支持 Multisite 子目录/子域名模式
# 参数: $1=DEST  $2=MS_TYPE(single|subdirectory|subdomain)  $3=MS_DOMAIN(子域名根域)
_write_nginx_wp_conf() {
    local DEST="$1"
    local MS_TYPE="${2:-single}"
    local MS_DOMAIN="${3:-}"

    # 子域名模式：通配符 server_name
    local SERVER_NAME_DIRECTIVE="server_name _;"
    if [[ "$MS_TYPE" == "subdomain" && -n "$MS_DOMAIN" ]]; then
        SERVER_NAME_DIRECTIVE="server_name ${MS_DOMAIN} *.${MS_DOMAIN};"
    fi

    # 子目录 Multisite 额外 rewrite 规则
    local MULTISITE_REWRITE_BLOCK=""
    if [[ "$MS_TYPE" == "subdirectory" ]]; then
        MULTISITE_REWRITE_BLOCK='
    # WordPress Multisite 子目录模式 rewrite
    if (!-e $request_filename) {
        rewrite /wp-admin$ $scheme://$host$uri/ permanent;
        rewrite ^(/[^/]+)?(/wp-.*) $2 last;
        rewrite ^(/[^/]+)?(/.*\.php) $2 last;
    }'
    fi

    # 用 printf 写文件，避免 heredoc 与变量展开的冲突
    {
        printf 'map $http_x_forwarded_proto $fastcgi_https {
'
        printf '    default "";
'
        printf '    https   "on";
'
        printf '}

'
        printf 'server {
'
        printf '    listen __WG_IP__:__WP_PORT__ default_server;
'
        printf '    %s
' "$SERVER_NAME_DIRECTIVE"
        printf '    root /var/www/html;
'
        printf '    index index.php index.html;
'
        printf '    client_max_body_size 2048M;
'
        printf '
'
        printf '    # 健康检查端点
'
        printf '    location = /health {
'
        printf '        access_log off;
'
        printf '        return 200 "ok";
'
        printf '        add_header Content-Type text/plain;
'
        printf '    }
'
        if [[ -n "$MULTISITE_REWRITE_BLOCK" ]]; then
            printf '%s
' "$MULTISITE_REWRITE_BLOCK"
        fi
        printf '
'
        printf '    location ~* \.(js|css|png|jpg|jpeg|gif|ico|svg|woff|woff2|webp|avif)$ {
'
        printf '        expires max;
'
        printf '        log_not_found off;
'
        printf '        add_header Cache-Control "public, immutable";
'
        printf '        try_files $uri =404;
'
        printf '    }
'
        printf '
'
        printf '    location / {
'
        printf '        try_files $uri $uri/ /index.php?$args;
'
        printf '    }
'
        printf '
'
        printf '    location ~ \.php$ {
'
        printf '        fastcgi_pass              127.0.0.1:9000;
'
        printf '        fastcgi_index             index.php;
'
        printf '        include                   fastcgi_params;
'
        printf '        fastcgi_param SCRIPT_FILENAME  $document_root$fastcgi_script_name;
'
        printf '        fastcgi_param HTTPS            $fastcgi_https if_not_empty;
'
        printf '        fastcgi_param HTTP_X_FORWARDED_PROTO $http_x_forwarded_proto;
'
        printf '        fastcgi_param HTTP_X_FORWARDED_FOR   $http_x_forwarded_for;
'
        printf '        fastcgi_param HTTP_X_REAL_IP         $http_x_real_ip;
'
        printf '        fastcgi_read_timeout      600;
'
        printf '        fastcgi_send_timeout      600;
'
        printf '        fastcgi_buffer_size       128k;
'
        printf '        fastcgi_buffers           4 256k;
'
        printf '    }
'
        printf '
'
        printf '    location ~* /(?:wp-config\.php|\.env|\.git|\.htaccess|xmlrpc\.php) {
'
        printf '        deny all;
'
        printf '    }
'
        printf '
'
        printf '    location ~* /wp-content/uploads/.*\.php$ {
'
        printf '        deny all;
'
        printf '    }
'
        printf '}
'
    } > "$DEST"
}

# v5.0: 占位符替换，在宿主机对已生成的 nginx-wp.conf 执行
# 用法: _sed_nginx_wp_conf <file> <wg_ip> <wp_port>
_sed_nginx_wp_conf() {
    local FILE="$1" WG_IP="$2" WP_PORT="$3"
    sed -i \
        -e "s/__WG_IP__/${WG_IP}/g" \
        -e "s/__WP_PORT__/${WP_PORT}/g" \
        "$FILE"
}

# v4.8: entrypoint 不再做任何 sed 替换（Alpine bind-mount rename(2) 跨设备问题）
_write_entrypoint_script() {
    local DEST="$1"
    cat > "$DEST" <<'ENTRYPOINT'
#!/bin/sh
set -e
echo "Starting supervisord..."
exec /usr/bin/supervisord -c /etc/supervisord.conf
ENTRYPOINT
    chmod +x "$DEST"
}

_write_php_uploads_ini() { cat > "$1" <<'INI'
upload_max_filesize = 2048M
post_max_size       = 2048M
memory_limit        = 512M
max_execution_time  = 600
max_input_time      = 600
max_input_vars      = 10000
INI
}

_write_opcache_ini() { cat > "$1" <<'INI'
opcache.enable=1
opcache.memory_consumption=256
opcache.interned_strings_buffer=16
opcache.max_accelerated_files=10000
opcache.revalidate_freq=0
opcache.validate_timestamps=0
opcache.fast_shutdown=1
opcache.enable_cli=0
INI
}

# ════════════════════════════════════════════════════════
# Redis 全页缓存（v6.5）
#   - advanced-cache.php: WordPress 原生 drop-in，WP_CACHE=true 时
#     wp-settings.php 会在几乎没加载任何东西之前 include 它，可以在此
#     直接输出缓存好的 HTML 并 exit，跳过整个 WP 加载流程。
#   - 是否生效由 wp-config-extra.php 里的 WP_PAGE_CACHE_ENABLED 常量
#     统一控制（随镜像分发到所有节点），本文件内容本身不区分开关状态，
#     即使 PAGE_CACHE_ENABLED=false 也可以放心随镜像分发，不会有副作用。
#   - 用独立的 Redis 逻辑库（SELECT 1），与对象缓存（db0）分开，
#     互不挤占、互不影响，出问题也方便单独排查/清空。
# ════════════════════════════════════════════════════════
_write_advanced_cache_php() {
    cat > "$1" <<'PHP'
<?php
// advanced-cache.php — Redis 全页缓存（自动生成，勿手动编辑）
// 开关由 wp-config-extra.php 中的 WP_PAGE_CACHE_ENABLED 常量控制
if (!defined('WP_PAGE_CACHE_ENABLED') || !WP_PAGE_CACHE_ENABLED) return;
if (($_SERVER['REQUEST_METHOD'] ?? '') !== 'GET') return;
if (!empty($_SERVER['QUERY_STRING'])) return;               // 带参数请求不缓存，简化正确性
$uri = $_SERVER['REQUEST_URI'] ?? '/';
if (strpos($uri, '/wp-admin') === 0
    || strpos($uri, '/wp-login') === 0
    || strpos($uri, '/wp-json') === 0
    || strpos($uri, '/wp-cron.php') === 0) {
    return;
}
foreach (array_keys($_COOKIE) as $_k) {
    // 登录用户 / 刚发表评论的访客：不缓存，避免看到别人的缓存页或缓存自己的过渡态
    if (strpos($_k, 'wordpress_logged_in_') === 0 || strpos($_k, 'comment_author_') === 0) {
        return;
    }
}
if (!extension_loaded('redis')) return;
if (!defined('WP_REDIS_HOST')) return;

$_pc_key = 'pagecache:' . (defined('WP_INSTANCE') ? WP_INSTANCE . ':' : '') . md5(
    ((!empty($_SERVER['HTTPS'])) ? 'https' : 'http') . '://' .
    ($_SERVER['HTTP_HOST'] ?? '') . $uri
);

try {
    $_pc_redis = new Redis();
    $_pc_redis->connect(WP_REDIS_HOST, 6379, 0.3);   // 300ms 超时，Redis 异常时不拖垮全站
    if (defined('WP_REDIS_PASSWORD') && WP_REDIS_PASSWORD !== '') {
        $_pc_redis->auth(WP_REDIS_PASSWORD);
    }
    $_pc_redis->select(1); // 独立逻辑库，与对象缓存(db0)分开

    $_pc_cached = $_pc_redis->get($_pc_key);
    if ($_pc_cached !== false) {
        header('X-Page-Cache: HIT');
        echo $_pc_cached;
        exit;
    }

    header('X-Page-Cache: MISS');
    ob_start(function ($html) use ($_pc_redis, $_pc_key) {
        if (function_exists('http_response_code') && http_response_code() === 200 && strlen($html) > 1000) {
            // 6 小时 TTL 兜底：即使某些页面漏了主动清缓存，也会自动过期，不会长期陈旧
            $_pc_redis->setex($_pc_key, 21600, $html);
        }
        return $html;
    });
} catch (\Throwable $e) {
    // Redis 不可用时静默降级为不缓存，绝不影响正常访问
    return;
}
PHP
}

_write_pagecache_purge_mu_plugin() {
    cat > "$1" <<'PHP'
<?php
// pagecache-purge.php — 文章状态变化时清对应的 Redis 页面缓存（自动生成，勿手动编辑）
// mu-plugin 无需手动激活，放进 wp-content/mu-plugins/ 即自动加载

function _pc_purge_post_urls($post_id) {
    if (!extension_loaded('redis') || !defined('WP_REDIS_HOST')) return;

    $urls = array_filter([home_url('/'), get_permalink($post_id)]);
    if (function_exists('get_the_category')) {
        foreach (get_the_category($post_id) as $cat) {
            $link = get_category_link($cat->term_id);
            if ($link && !is_wp_error($link)) $urls[] = $link;
        }
    }

    try {
        $redis = new Redis();
        $redis->connect(WP_REDIS_HOST, 6379, 0.3);
        if (defined('WP_REDIS_PASSWORD') && WP_REDIS_PASSWORD !== '') {
            $redis->auth(WP_REDIS_PASSWORD);
        }
        $redis->select(1);
        foreach ($urls as $url) {
            $p = wp_parse_url($url);
            if (empty($p['host'])) continue;
            $scheme = $p['scheme'] ?? 'http';
            $path   = $p['path']   ?? '/';
            $redis->del('pagecache:' . (defined('WP_INSTANCE') ? WP_INSTANCE . ':' : '') . md5("{$scheme}://{$p['host']}{$path}"));
        }
    } catch (\Throwable $e) {
        // 静默失败：漏清的 key 靠 advanced-cache.php 里的 6 小时 TTL 自动兜底
    }
}

// 编辑/重新发表已发布文章：清首页 + 该文章 + 所在分类页
add_action('save_post', function ($post_id) {
    if (!defined('WP_PAGE_CACHE_ENABLED') || !WP_PAGE_CACHE_ENABLED) return;
    if (wp_is_post_revision($post_id) || wp_is_post_autosave($post_id)) return;

    $post = get_post($post_id);
    if (!$post || $post->post_status !== 'publish') return;

    _pc_purge_post_urls($post_id);
}, 20);

// [fix] v6.6: 原来只挂 save_post 且要求 post_status==='publish'，文章被下架/移入回收站时
// save_post 触发时状态已经是 trash，直接被上面的判断拦掉，导致下架后首页/文章页缓存
// 继续展示已下架内容，最长要等 6 小时 TTL 才会自动过期。这里补一个“曾发布→现在不是
// 发布”的转场钩子，专门覆盖下架场景，避免和 save_post 重复清理。
add_action('transition_post_status', function ($new_status, $old_status, $post) {
    if (!defined('WP_PAGE_CACHE_ENABLED') || !WP_PAGE_CACHE_ENABLED) return;
    if ($old_status !== 'publish' || $new_status === 'publish') return;
    _pc_purge_post_urls($post->ID);
}, 20, 3);
PHP
}

_write_php_fpm_www_conf() { cat > "$1" <<'CONF'
[www]
user  = www-data
group = www-data
listen = 127.0.0.1:9000
listen.owner = www-data
listen.group = www-data
listen.mode  = 0660
pm                   = dynamic
pm.max_children      = 20
pm.start_servers     = 4
pm.min_spare_servers = 2
pm.max_spare_servers = 6
pm.max_requests      = 500
php_admin_value[error_log]  = /dev/stderr
php_admin_flag[log_errors]  = on
security.limit_extensions = .php
CONF
}

# v6.0:
#   - 新增 Multisite 常量注入
# v6.4:
#   - 新增 R2 / Advanced Media Offloader 常量，字面量烘焙进文件（随镜像分发），
#     不再依赖容器 getenv()，主/工作节点共享同一份，不需要逐节点配置 .env
# v6.5:
#   - 新增 $18=PAGE_CACHE_ENABLED，与 Multisite 参数同样字面量烘焙、
#     主/工作节点都传（不像 R2 凭证那样只在主节点传），确保全节点开关一致
# 参数: $1=DEST $2=NODE_ROLE $3...$10=8个 salt 值
#       $11=MS_TYPE(single|subdirectory|subdomain)  $12=MS_DOMAIN
#       $13=R2_KEY $14=R2_SECRET $15=R2_BUCKET $16=R2_DOMAIN $17=R2_ENDPOINT
#       $18=PAGE_CACHE_ENABLED(true|false)
_write_wp_config_extra() {
    local DEST="$1"
    local NODE_ROLE="${2:-worker}"
    local AUTH_KEY="${3:-}"
    local SECURE_AUTH_KEY="${4:-}"
    local LOGGED_IN_KEY="${5:-}"
    local NONCE_KEY="${6:-}"
    local AUTH_SALT="${7:-}"
    local SECURE_AUTH_SALT="${8:-}"
    local LOGGED_IN_SALT="${9:-}"
    local NONCE_SALT="${10:-}"
    local MS_TYPE="${11:-single}"
    local MS_DOMAIN="${12:-}"
    local R2_KEY="${13:-}"
    local R2_SECRET="${14:-}"
    local R2_BUCKET="${15:-}"
    local R2_DOMAIN="${16:-}"
    local R2_ENDPOINT="${17:-}"
    local PAGE_CACHE_ENABLED="${18:-false}"
    [[ "$PAGE_CACHE_ENABLED" == "true" ]] || PAGE_CACHE_ENABLED="false"

    # 如果没有传入 salts（如老的调用路径），生成临时值并告警
    if [[ -z "$AUTH_KEY" ]]; then
        warn "_write_wp_config_extra: 未传入 salts，将生成随机值（各节点可能不一致）"
        AUTH_KEY=$(_gen_salt); SECURE_AUTH_KEY=$(_gen_salt)
        LOGGED_IN_KEY=$(_gen_salt); NONCE_KEY=$(_gen_salt)
        AUTH_SALT=$(_gen_salt); SECURE_AUTH_SALT=$(_gen_salt)
        LOGGED_IN_SALT=$(_gen_salt); NONCE_SALT=$(_gen_salt)
    fi

    # 写文件（不用 heredoc 以避免 salt 特殊字符需要转义）
    {
        printf '<?php\n'
        printf '// === 自动生成，勿手动编辑 ===\n\n'

        printf '// 安全认证密钥（多节点统一，确保 cookie 互认）\n'
        printf "define('AUTH_KEY',         '%s');\n" "${AUTH_KEY//\'/\\\'}"
        printf "define('SECURE_AUTH_KEY',  '%s');\n" "${SECURE_AUTH_KEY//\'/\\\'}"
        printf "define('LOGGED_IN_KEY',    '%s');\n" "${LOGGED_IN_KEY//\'/\\\'}"
        printf "define('NONCE_KEY',        '%s');\n" "${NONCE_KEY//\'/\\\'}"
        printf "define('AUTH_SALT',        '%s');\n" "${AUTH_SALT//\'/\\\'}"
        printf "define('SECURE_AUTH_SALT', '%s');\n" "${SECURE_AUTH_SALT//\'/\\\'}"
        printf "define('LOGGED_IN_SALT',   '%s');\n" "${LOGGED_IN_SALT//\'/\\\'}"
        printf "define('NONCE_SALT',       '%s');\n\n" "${NONCE_SALT//\'/\\\'}"

        printf '// 更新与调试\n'
        printf "define('AUTOMATIC_UPDATER_DISABLED', true);\n"
        printf "define('WP_AUTO_UPDATE_CORE',        false);\n"

        printf '// WP-Cron: 禁用内置触发，由宿主机 cron 调用 wp-cli\n'
        printf "define('DISABLE_WP_CRON',    true);\n"
        printf "define('ALTERNATE_WP_CRON',  false);\n\n"

        if [[ "$NODE_ROLE" == "worker" ]]; then
            printf "define('DISALLOW_FILE_MODS', true);\n\n"
        fi

        cat <<'PHP_BODY'
function _wp_is_trusted_proxy(string $ip): bool {
    return (bool) preg_match(
        '/^(10\.|172\.(1[6-9]|2\d|3[01])\.|192\.168\.)/',
        $ip
    );
}

if (php_sapi_name() !== 'cli') {
    $remote = $_SERVER['REMOTE_ADDR'] ?? '';
    if (_wp_is_trusted_proxy($remote)) {
        if (($_SERVER['HTTP_X_FORWARDED_PROTO'] ?? '') === 'https') {
            $_SERVER['HTTPS'] = 'on';
        }
        $fwd_host = trim(explode(',', $_SERVER['HTTP_X_FORWARDED_HOST'] ?? '')[0]);
        if ($fwd_host !== '') {
            $scheme   = ($_SERVER['HTTPS'] ?? '') === 'on' ? 'https' : 'http';
            $site_url = $scheme . '://' . $fwd_host;
            if (!defined('WP_HOME')) {
                define('WP_HOME',    $site_url);
                define('WP_SITEURL', $site_url);
            }
        }
    }
    if (!defined('WP_HOME')) {
        $fallback = getenv('WP_SITEURL_FALLBACK') ?: '';
        if ($fallback !== '') {
            define('WP_HOME',    $fallback);
            define('WP_SITEURL', $fallback);
        }
    }
}

$_redis_host = getenv('REDIS_HOST') ?: '127.0.0.1';
$_redis_pw   = getenv('REDIS_PW')   ?: '';
if (!defined('WP_REDIS_HOST')) {
    define('WP_REDIS_HOST',     $_redis_host);
    define('WP_REDIS_PORT',     6379);
    define('WP_REDIS_PASSWORD', $_redis_pw);
    define('WP_CACHE',          true);
}
define('WP_MEMORY_LIMIT',     '512M');
define('WP_MAX_MEMORY_LIMIT', '1024M');

if (extension_loaded('redis') && php_sapi_name() !== 'cli' && !headers_sent()) {
    ini_set('session.save_handler', 'redis');
    ini_set('session.save_path',
        'tcp://' . $_redis_host . ':6379?auth=' . urlencode($_redis_pw));
}
PHP_BODY

        # [fix] v6.6: 之前这里从未输出 WP_PAGE_CACHE_ENABLED 常量，导致 $18 参数
        # 传了也是白传，advanced-cache.php 里 !defined(...) 恒为真，缓存永远不生效
        printf '\n// Redis 全页缓存开关（由 PAGE_CACHE_ENABLED 控制，见 advanced-cache.php）\n'
        printf "define('WP_PAGE_CACHE_ENABLED', %s);\n" "$PAGE_CACHE_ENABLED"

        # Multisite 常量
        if [[ "$MS_TYPE" == "subdirectory" || "$MS_TYPE" == "subdomain" ]]; then
            printf '\n// WordPress Multisite\n'
            printf "define('WP_ALLOW_MULTISITE', true);\n"
            printf "define('MULTISITE',          true);\n"
            if [[ "$MS_TYPE" == "subdomain" ]]; then
                printf "define('SUBDOMAIN_INSTALL',  true);\n"
            else
                printf "define('SUBDOMAIN_INSTALL',  false);\n"
            fi
            if [[ -n "$MS_DOMAIN" ]]; then
                printf "define('DOMAIN_CURRENT_SITE', '%s');\n" "$MS_DOMAIN"
            else
                printf "// DOMAIN_CURRENT_SITE 由运行时 HTTP_HOST 决定\n"
                printf 'if (!defined("DOMAIN_CURRENT_SITE")) define("DOMAIN_CURRENT_SITE", $_SERVER["HTTP_HOST"] ?? "localhost");
'
            fi
            printf "define('PATH_CURRENT_SITE',    '/');\n"
            printf "define('SITE_ID_CURRENT_SITE', 1);\n"
            printf "define('BLOG_ID_CURRENT_SITE', 1);\n"
        fi

        # v6.4: Advanced Media Offloader - Cloudflare R2
        # 字面量烘焙进文件（随镜像分发到所有节点），不再依赖 .env / getenv()
        if [[ -n "$R2_KEY" ]]; then
            printf '\n// Advanced Media Offloader - Cloudflare R2\n'
            printf "define('ADVMO_CLOUDFLARE_R2_KEY',      '%s');\n" "${R2_KEY//\'/\\\'}"
            printf "define('ADVMO_CLOUDFLARE_R2_SECRET',   '%s');\n" "${R2_SECRET//\'/\\\'}"
            printf "define('ADVMO_CLOUDFLARE_R2_BUCKET',   '%s');\n" "${R2_BUCKET//\'/\\\'}"
            printf "define('ADVMO_CLOUDFLARE_R2_DOMAIN',   '%s');\n" "${R2_DOMAIN//\'/\\\'}"
            printf "define('ADVMO_CLOUDFLARE_R2_ENDPOINT', '%s');\n" "${R2_ENDPOINT//\'/\\\'}"
        fi
    } > "$DEST"
    # [fix] v6.7: 此文件含 8 个 WP salts + 主节点的 R2 Secret Access Key，
    # 默认 umask 下落盘后是明文可被本机其他用户读取，写完立即收紧权限。
    chmod 600 "$DEST" 2>/dev/null || true
}

_write_master_dockerfile() {
    local DIR="$1"
    cat > "$DIR/Dockerfile" <<'DOCKERFILE'
FROM php:8.4-fpm-alpine

RUN apk add --no-cache \
        nginx supervisor curl bash \
        libpng libpng-dev libjpeg-turbo libjpeg-turbo-dev \
        libwebp-dev freetype freetype-dev icu-dev libzip-dev zip unzip \
        imagemagick imagemagick-dev \
    && docker-php-ext-configure gd --with-freetype --with-jpeg --with-webp \
    && docker-php-ext-install -j$(nproc) gd mysqli zip intl exif opcache \
    && apk add --no-cache --virtual .build-deps $PHPIZE_DEPS \
    && pecl install redis imagick \
    && docker-php-ext-enable redis imagick \
    && apk del .build-deps libpng-dev libjpeg-turbo-dev freetype-dev imagemagick-dev \
    && rm -rf /tmp/pear /var/cache/apk/*

ARG WP_CLI_VERSION=2.12.0
RUN curl -4 -fsSL "https://github.com/wp-cli/wp-cli/releases/download/v${WP_CLI_VERSION}/wp-cli-${WP_CLI_VERSION}.phar" \
        -o /usr/local/bin/wp \
    && chmod +x /usr/local/bin/wp \
    && php /usr/local/bin/wp --allow-root --version | grep -q "${WP_CLI_VERSION}" \
    || (echo "wp-cli version mismatch or corrupted download" && exit 1)

COPY wp-core/ /var/www/html/
RUN rm -f /var/www/html/wp-config.php /var/www/html/wp-config-sample.php

COPY wp-content/themes/   /var/www/html/wp-content/themes/
COPY wp-content/plugins/  /var/www/html/wp-content/plugins/

COPY conf/nginx.conf            /etc/nginx/nginx.conf
COPY conf/nginx-wp.conf         /etc/nginx/http.d/default.conf
COPY conf/php-uploads.ini       /usr/local/etc/php/conf.d/uploads.ini
COPY conf/opcache.ini           /usr/local/etc/php/conf.d/opcache.ini
COPY conf/php-fpm-www.conf      /usr/local/etc/php-fpm.d/www.conf
COPY conf/supervisord.conf      /etc/supervisord.conf
# [fix] wp-config-extra.php 必须打入镜像，cmd_pull_deploy 会从镜像里 docker cp 取出
# 并放到 worker 宿主机的 conf/ 目录，再由 _write_worker_compose 以 bind mount(:ro) 挂载。
# 若不打入镜像，docker cp 失败 → 宿主机 conf/wp-config-extra.php 不存在 →
# Docker 把 bind mount 源当目录创建 → PHP require_once 拿到目录 → Fatal Error → 全站 500。
COPY conf/wp-config-extra.php   /etc/wordpress/wp-config-extra.php
# [fix] v6.6: 同样的原因（见上面 wp-config-extra.php 的注释）打进镜像：
# cmd_pull_deploy 会 docker cp 取出这两个文件放到宿主机 conf/，再由
# _write_worker_compose bind mount(:ro) 覆盖回同样的路径。若不打入镜像，
# docker cp 会失败，宿主机文件缺失导致 Docker 把 bind mount 源当目录创建，
# advanced-cache.php/mu-plugins/pagecache-purge.php 变成目录 → 全站 500。
COPY conf/advanced-cache.php    /var/www/html/wp-content/advanced-cache.php
COPY conf/pagecache-purge.php   /var/www/html/wp-content/mu-plugins/pagecache-purge.php
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

RUN mkdir -p /var/log/nginx /var/log/supervisor /run/nginx \
             /var/lib/nginx/tmp/client_body \
             /var/lib/nginx/tmp/fastcgi \
             /var/lib/nginx/tmp/proxy \
             /var/lib/nginx/tmp/scgi \
             /var/lib/nginx/tmp/uwsgi \
             /var/www/html/wp-content/uploads \
             /var/www/html/wp-content/cache /etc/wordpress \
    && chown -R www-data:www-data /var/www/html \
    && chown -R www-data:www-data /var/lib/nginx \
    && chmod -R 755 /var/www/html

EXPOSE 80
CMD ["/entrypoint.sh"]
DOCKERFILE

    cat > "$DIR/.dockerignore" <<'IGNORE'
wp-config.php
wp-config-sample.php
.env
.git
.htaccess
wp-content/uploads/*
wp-content/cache/*
!wp-content/uploads/.gitkeep
IGNORE
}

_write_init_dockerfile() {
    local DIR="$1"
    cat > "$DIR/Dockerfile" <<'DOCKERFILE'
FROM php:8.4-fpm-alpine

RUN apk add --no-cache \
        nginx supervisor curl bash \
        libpng libpng-dev libjpeg-turbo libjpeg-turbo-dev \
        libwebp-dev freetype freetype-dev icu-dev libzip-dev zip unzip \
        imagemagick imagemagick-dev \
    && docker-php-ext-configure gd --with-freetype --with-jpeg --with-webp \
    && docker-php-ext-install -j$(nproc) gd mysqli zip intl exif opcache \
    && apk add --no-cache --virtual .build-deps $PHPIZE_DEPS \
    && pecl install redis imagick \
    && docker-php-ext-enable redis imagick \
    && apk del .build-deps libpng-dev libjpeg-turbo-dev freetype-dev imagemagick-dev \
    && rm -rf /tmp/pear /var/cache/apk/*

ARG WP_CLI_VERSION=2.12.0
RUN curl -4 -fsSL "https://github.com/wp-cli/wp-cli/releases/download/v${WP_CLI_VERSION}/wp-cli-${WP_CLI_VERSION}.phar" \
        -o /usr/local/bin/wp \
    && chmod +x /usr/local/bin/wp \
    && php /usr/local/bin/wp --allow-root --version | grep -q "${WP_CLI_VERSION}" \
    || (echo "wp-cli version mismatch or corrupted download" && exit 1)

RUN curl -4 -fsSL https://wordpress.org/latest.tar.gz \
        | tar -xz -C /var/www/html --strip-components=1 \
    && chown -R www-data:www-data /var/www/html \
    && chmod -R 755 /var/www/html

COPY conf/php-fpm-www.conf /usr/local/etc/php-fpm.d/www.conf
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

RUN mkdir -p /var/log/nginx /var/log/supervisor /run/nginx \
             /var/lib/nginx/tmp/client_body \
             /var/lib/nginx/tmp/fastcgi \
             /var/lib/nginx/tmp/proxy \
             /var/lib/nginx/tmp/scgi \
             /var/lib/nginx/tmp/uwsgi \
             /var/www/html/wp-content/uploads /etc/wordpress \
    && chown -R www-data:www-data /var/lib/nginx

EXPOSE 80
CMD ["/entrypoint.sh"]
DOCKERFILE

    # [fix] .dockerignore 和 Dockerfile 放在一起（_write_master_dockerfile 同理）。
    # 之前误放在 _write_init_compose，概念错位：.dockerignore 控制 docker build 上下文，
    # 与 compose 无关。
    # [fix] 原来写 wp-config.php 匹配不到 conf/wp-config.php（build context 根是 $DIR）。
    cat > "$DIR/.dockerignore" <<'IGNORE'
.env
conf/wp-config.php
conf/wp-config-extra.php
wp-config-sample.php
.git
.htaccess
data/uploads/*
data/cache/*
logs/*
IGNORE
}

_write_init_compose() {
    local DIR="$1"
    local INST="${2:-${INSTANCE}}"
    # [fix] 镜像名带实例名后缀，多实例并发初始化时互不覆盖
    cat > "$DIR/docker-compose.yml" <<YAML
services:
  wordpress:
    build:
      context: .
      dockerfile: Dockerfile
    image: wordpress-${INST}-init:latest
    restart: unless-stopped
    network_mode: host
    environment:
      WG_IP:                  \${WG_IP}
      WP_PORT:                \${WP_PORT:-80}
      WORDPRESS_DB_HOST:      \${DB_HOST}:3306
      WORDPRESS_DB_NAME:      \${WORDPRESS_DB_NAME}
      WORDPRESS_DB_USER:      \${WORDPRESS_DB_USER}
      WORDPRESS_DB_PASSWORD:  \${WORDPRESS_DB_PASSWORD}
      REDIS_HOST:             \${REDIS_HOST}
      REDIS_PW:               \${REDIS_PW}
      WP_SITEURL_FALLBACK:    \${WP_SITEURL_FALLBACK}
    volumes:
      - ./data/uploads:/var/www/html/wp-content/uploads
      - ./data/cache:/var/www/html/wp-content/cache
      - ./conf/nginx.conf:/etc/nginx/nginx.conf:ro
      - ./conf/nginx-wp.conf:/etc/nginx/http.d/default.conf:ro
      - ./conf/php-uploads.ini:/usr/local/etc/php/conf.d/uploads.ini:ro
      - ./conf/opcache.ini:/usr/local/etc/php/conf.d/opcache.ini:ro
      - ./conf/php-fpm-www.conf:/usr/local/etc/php-fpm.d/www.conf:ro
      - ./conf/supervisord.conf:/etc/supervisord.conf:ro
      - ./conf/wp-config.php:/var/www/html/wp-config.php
      - ./conf/wp-config-extra.php:/etc/wordpress/wp-config-extra.php:ro
      - ./conf/advanced-cache.php:/var/www/html/wp-content/advanced-cache.php:ro
      - ./conf/pagecache-purge.php:/var/www/html/wp-content/mu-plugins/pagecache-purge.php:ro
      - ./logs:/var/log/nginx
YAML
}

_write_worker_compose() {
    local DIR="$1"
    local INST="${2:-${INSTANCE}}"   # 接收实例名，fallback 到全局 INSTANCE
    # $3: wp-config.php 挂载模式，默认只读(ro)。仅在首次部署生成 wp-config.php
    #     的引导阶段传入 "rw"，生成完成后必须重写回 "ro" 再做最终启动，
    #     避免 worker 节点对 wp-config.php 保持长期可写。
    local WPCFG_MODE="${3:-ro}"
    [[ "$WPCFG_MODE" == "ro" || "$WPCFG_MODE" == "rw" ]] || { warn "_write_worker_compose: 无效 WPCFG_MODE='${WPCFG_MODE}'，已回退为 ro"; WPCFG_MODE="ro"; }
    local WPCFG_SUFFIX=":ro"
    [[ "$WPCFG_MODE" == "rw" ]] && WPCFG_SUFFIX=""
    # 注意：此处不能用 heredoc + 单引号（'YAML'）否则变量无法展开，
    # 改用 printf / cat 拼接，只让 INST/WPCFG_SUFFIX 展开，其余 ${...} 保留为 compose 变量
    cat > "$DIR/docker-compose.yml" <<YAML
services:
  wordpress:
    image: \${REGISTRY_HOST}/wordpress-${INST}:\${IMAGE_TAG:-latest}
    restart: unless-stopped
    network_mode: host
    environment:
      WG_IP:                  \${WG_IP}
      WP_PORT:                \${WP_PORT:-80}
      WORDPRESS_DB_HOST:      \${DB_HOST}:3306
      WORDPRESS_DB_NAME:      \${WORDPRESS_DB_NAME}
      WORDPRESS_DB_USER:      \${WORDPRESS_DB_USER}
      WORDPRESS_DB_PASSWORD:  \${WORDPRESS_DB_PASSWORD}
      REDIS_HOST:             \${REDIS_HOST}
      REDIS_PW:               \${REDIS_PW}
      WP_SITEURL_FALLBACK:    \${WP_SITEURL_FALLBACK}
    volumes:
      - ./data/uploads:/var/www/html/wp-content/uploads
      - ./data/cache:/var/www/html/wp-content/cache
      - ./conf/nginx.conf:/etc/nginx/nginx.conf:ro
      - ./conf/nginx-wp.conf:/etc/nginx/http.d/default.conf:ro
      - ./conf/php-uploads.ini:/usr/local/etc/php/conf.d/uploads.ini:ro
      - ./conf/opcache.ini:/usr/local/etc/php/conf.d/opcache.ini:ro
      - ./conf/php-fpm-www.conf:/usr/local/etc/php-fpm.d/www.conf:ro
      - ./conf/supervisord.conf:/etc/supervisord.conf:ro
      - ./conf/wp-config.php:/var/www/html/wp-config.php${WPCFG_SUFFIX}
      - ./conf/wp-config-extra.php:/etc/wordpress/wp-config-extra.php:ro
      - ./conf/advanced-cache.php:/var/www/html/wp-content/advanced-cache.php:ro
      - ./conf/pagecache-purge.php:/var/www/html/wp-content/mu-plugins/pagecache-purge.php:ro
      - ./logs:/var/log/nginx
YAML
}

# ════════════════════════════════════════════════════════
# 缓存刷新
# ════════════════════════════════════════════════════════
_flush_all_caches() {
    local DIR="$1"
    info "刷新缓存..."

    dc "$DIR" exec -T wordpress sh -c \
        'PID_FILE=$(find /var/run -name "php-fpm.pid" 2>/dev/null | head -1)
         [ -n "$PID_FILE" ] && kill -USR2 $(cat "$PID_FILE") || pkill -USR2 php-fpm || true' \
    2>/dev/null && info "  OPcache 已重置" || warn "  OPcache 重置失败（可忽略）"

    dc "$DIR" exec -T wordpress wp --allow-root cache flush 2>/dev/null \
    && info "  Redis 对象缓存已刷新" || warn "  Redis 对象缓存刷新失败"

    # [fix] v6.6: 之前只 flush 了对象缓存（db0），页面缓存独立用 db1（select 1），
    # 从未被这里清过，导致关闭/开启页面缓存开关或强制刷新时，旧页面仍会命中缓存
    local _PC_FLUSH
    _PC_FLUSH=$(dc "$DIR" exec -T wordpress wp --allow-root eval '
        $h = getenv("REDIS_HOST") ?: "127.0.0.1";
        $p = getenv("REDIS_PW")   ?: "";
        try {
            $r = new Redis();
            $r->connect($h, 6379, 0.5);
            if ($p !== "") { $r->auth($p); }
            $r->select(1);
            $r->flushDB();
            echo "OK";
        } catch (\Throwable $e) {
            echo "FAIL";
        }
    ' 2>/dev/null || true)
    [[ "$_PC_FLUSH" == "OK" ]] \
    && info "  Redis 页面缓存（db1）已清空" || warn "  Redis 页面缓存清空失败（可忽略，6小时TTL会自动过期）"

    dc "$DIR" exec -T wordpress wp --allow-root rewrite flush 2>/dev/null \
    && info "  Rewrite rules 已刷新" || warn "  Rewrite rules 刷新失败"

    local NGINX_CACHE_DIR
    NGINX_CACHE_DIR=$(dc "$DIR" exec -T wordpress \
        sh -c 'grep -r fastcgi_cache_path /etc/nginx/ 2>/dev/null \
               | grep -oP "(?<=fastcgi_cache_path )[^ ]+" | head -1' 2>/dev/null || true)
    if [[ -n "$NGINX_CACHE_DIR" && "$NGINX_CACHE_DIR" =~ ^/[a-zA-Z0-9/_-]+$ ]]; then
        dc "$DIR" exec -T wordpress sh -c "rm -rf ${NGINX_CACHE_DIR}/* 2>/dev/null || true" \
        && info "  Nginx fastcgi_cache 已清理" || warn "  Nginx cache 清理失败"
    elif [[ -n "$NGINX_CACHE_DIR" ]]; then
        warn "  NGINX_CACHE_DIR 路径格式异常，已跳过清理: ${NGINX_CACHE_DIR}"
    fi

    local CF_TOKEN CF_ZONE_ID
    CF_TOKEN=$(env_get "$DIR/.env" "CF_TOKEN")
    CF_ZONE_ID=$(env_get "$DIR/.env" "CF_ZONE_ID")
    if [[ -n "$CF_TOKEN" && -n "$CF_ZONE_ID" ]]; then
        info "  Cloudflare purge..."
        local CF_RESP
        CF_RESP=$(curl -sS -X POST \
            "https://api.cloudflare.com/client/v4/zones/${CF_ZONE_ID}/purge_cache" \
            -H "Authorization: Bearer ${CF_TOKEN}" \
            -H "Content-Type: application/json" \
            --data '{"purge_everything":true}' 2>/dev/null)
        echo "$CF_RESP" | jq -e '.success' &>/dev/null \
        && info "  Cloudflare 缓存已清除" || warn "  Cloudflare purge 失败：${CF_RESP}"
    fi

    log "缓存刷新完成"
}

# ════════════════════════════════════════════════════════
# _wp_config_create_with_extra
#   统一封装 wp-config.php 生成逻辑：
#   - 用 --skip-salts 跳过随机 KEY/SALT（由 wp-config-extra.php 统一管理），
#     避免事后 sed 删行
#   - 用 --extra-php 让 WP-CLI 把 require_once 插入到
#     "/* That's all, stop editing! */" 之前，避免手写正则 sed 插入
#   参数: $1=DIR  $2..$5=DB_NAME DB_USER DB_PW DB_HOST
#   返回: 0=成功 1=失败
# ════════════════════════════════════════════════════════
# [fix] v6.7: 原来用 dc ... exec -T wordpress sh -c "... --dbpass='${DB_PW}' ..."，
# 数据库密码是这条 sh -c 命令的参数文本，docker-compose 在宿主机上执行期间，
# 进程 argv（ps aux / /proc/<pid>/cmdline，两者默认对本机所有用户可读）会
# 完整包含明文密码。改为把要执行的命令写进一个宿主机上权限 600 的临时脚本，
# docker cp 进容器后再用容器内路径执行、执行完立即删除，密码只出现在
# 文件内容里，不会出现在任何进程的命令行参数中。
_wp_config_create_with_extra() {
    local DIR="$1" DB_NAME="$2" DB_USER="$3" DB_PW="$4" DB_HOST="$5"

    local _CID
    _CID=$(dc "$DIR" ps -q wordpress 2>/dev/null)
    [[ -n "$_CID" ]] || { warn "_wp_config_create_with_extra: 未找到运行中的 wordpress 容器"; return 1; }

    local _SCRIPT_LOCAL; _SCRIPT_LOCAL=$(mktemp)
    chmod 600 "$_SCRIPT_LOCAL"
    cat > "$_SCRIPT_LOCAL" <<SCRIPT
wp --allow-root config create \\
    --dbname='${DB_NAME}' --dbuser='${DB_USER}' --dbpass='${DB_PW}' \\
    --dbhost='${DB_HOST}' --dbcharset=utf8mb4 --skip-check --skip-salts \\
    --force \\
    --extra-php <<'PHP'
require_once('/etc/wordpress/wp-config-extra.php');
PHP
SCRIPT

    local _SCRIPT_REMOTE="/tmp/.wpcfg-$(date +%s%N)-$$.sh"
    local _RC=1
    if docker cp "$_SCRIPT_LOCAL" "${_CID}:${_SCRIPT_REMOTE}" 2>/dev/null; then
        docker exec "$_CID" chmod 600 "$_SCRIPT_REMOTE" 2>/dev/null || true
        docker exec "$_CID" sh "$_SCRIPT_REMOTE"
        _RC=$?
        docker exec "$_CID" rm -f "$_SCRIPT_REMOTE" 2>/dev/null || true
    fi
    rm -f "$_SCRIPT_LOCAL"
    return "$_RC"
}

# ════════════════════════════════════════════════════════
# _setup_plugins
# ════════════════════════════════════════════════════════
_setup_plugins() {
    local DIR="$1"
    local IS_AUTO_INSTALL="${2:-false}"
    local URL="${3:-}" TITLE="${4:-}" ADMIN="${5:-}"
    local PASS="${6:-}" EMAIL="${7:-}" LOCALE="${8:-zh_CN}"
    # v6.0: Multisite 参数（从 .env 自动读取，此处接收覆盖值）
    local MS_TYPE="${9:-}"
    local MS_DOMAIN="${10:-}"
    # 未传入则从 .env 读取
    [[ -z "$MS_TYPE" ]] && MS_TYPE=$(env_get "$DIR/.env" "WP_MULTISITE_TYPE" 2>/dev/null || true)
    [[ -z "$MS_DOMAIN" ]] && MS_DOMAIN=$(env_get "$DIR/.env" "WP_MULTISITE_DOMAIN" 2>/dev/null || true)
    MS_TYPE="${MS_TYPE:-single}"

    info "等待 WordPress 容器就绪..."
    local RETRIES=30
    local -a WP_CMD
    # 直接展开为完整命令数组，避免 function-in-array 的未定义行为
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

    # [fix] v6.4: wp-config.php 现在是宿主机 bind mount，启动前会被 touch 成空文件，
    # 用 -f 判断会永远为真而跳过生成；改用 -s 判断"非空"才算已生成
    if ! dc "$DIR" exec -T wordpress test -s /var/www/html/wp-config.php; then
        info "创建 wp-config.php ..."
        local DB_NAME DB_USER DB_PW DB_HOST
        DB_NAME=$(env_get "$DIR/.env" "WORDPRESS_DB_NAME")
        DB_USER=$(env_get "$DIR/.env" "WORDPRESS_DB_USER")
        DB_PW=$(env_get "$DIR/.env" "WORDPRESS_DB_PASSWORD")
        DB_HOST=$(env_get "$DIR/.env" "DB_HOST")

        _wp_config_create_with_extra "$DIR" "$DB_NAME" "$DB_USER" "$DB_PW" "$DB_HOST" \
            || { warn "wp-config.php 创建失败，请检查数据库连接。"; return 1; }
        log "wp-config.php 已自动生成。"

        # [fix] v6.4: 主节点 wp-config.php 此前只存在于容器可写层，
        # --force-recreate（如菜单17修改R2配置后的重启）会导致其丢失，
        # 进而触发 WordPress 重新走安装向导。这里生成后立即导出落盘，
        # 并配合 _write_init_compose 中新增的 bind mount 持久化。
        local _CID_FOR_CFG
        _CID_FOR_CFG=$(dc "$DIR" ps -q wordpress 2>/dev/null)
        if [[ -n "$_CID_FOR_CFG" ]]; then
            dc "$DIR" exec -T wordpress cp /var/www/html/wp-config.php /tmp/wp-config-out.php \
            && docker cp "${_CID_FOR_CFG}:/tmp/wp-config-out.php" "$DIR/conf/wp-config.php" \
            && chmod 600 "$DIR/conf/wp-config.php" \
            && log "wp-config.php 已落盘到 ${DIR}/conf/，重建容器不会再丢失" \
            || warn "wp-config.php 落盘失败，重建容器（如菜单17）仍有丢失风险，请手动执行菜单11修复"
        else
            warn "未取得容器 ID，wp-config.php 未落盘，重建容器仍有丢失风险"
        fi
    fi

    if [[ "$IS_AUTO_INSTALL" == "true" ]]; then
        if ! "${WP_CMD[@]}" core is-installed &>/dev/null; then
            info "安装 WordPress 核心..."
            "${WP_CMD[@]}" core install \
                --url="$URL" --title="$TITLE" \
                --admin_user="$ADMIN" --admin_password="$PASS" \
                --admin_email="$EMAIL" --locale="$LOCALE" --skip-email \
            || { warn "安装失败，请查看日志。"; return 1; }
            log "WordPress 安装成功！"
            echo -e "  站点: \e[32m${URL}\e[0m"
            echo -e "  账号: \e[32m${ADMIN}\e[0m / 密码: \e[32m${PASS}\e[0m"

            # v6.2: Multisite 安装
            if [[ "$MS_TYPE" == "subdirectory" || "$MS_TYPE" == "subdomain" ]]; then
                info "配置 WordPress Multisite (${MS_TYPE})..."
                local -a _MS_FLAGS=()
                [[ "$MS_TYPE" == "subdomain" ]] && _MS_FLAGS=("--subdomains")
                local _MS_ERR; _MS_ERR=$(mktemp)
                if "${WP_CMD[@]}" core multisite-convert "${_MS_FLAGS[@]}" 2>"$_MS_ERR"; then
                    log "Multisite 已启用（${MS_TYPE} 模式）"
                    if [[ "$MS_TYPE" == "subdomain" && -n "$MS_DOMAIN" ]]; then
                        info "  根域名: ${MS_DOMAIN}（确保 DNS 通配符解析已配置）"
                    fi
                    rm -f "$_MS_ERR"
                    # 转换后必须重启容器，使 wp-config-extra.php 中的 Multisite 常量生效，
                    # 否则后续 WP-CLI 命令无法在 Multisite 上下文中定位站点
                    info "重启容器以应用 Multisite 常量..."
                    dc "$DIR" restart wordpress 2>/dev/null || true
                    local _MS_WAIT=20
                    while ! "${WP_CMD[@]}" cli version &>/dev/null; do
                        sleep 3
                        _MS_WAIT=$((_MS_WAIT - 1))
                        if [[ $_MS_WAIT -le 0 ]]; then
                            warn "容器重启后未就绪，已中止后续插件配置（语言包/Redis），请稍后执行菜单11重试"
                            return 1
                        fi
                    done
                else
                    warn "Multisite 转换失败，请在后台手动完成（工具→网络设置）"
                    if [[ -s "$_MS_ERR" ]]; then
                        warn "错误详情："
                        sed 's/^/    /' "$_MS_ERR" >&2
                    fi
                    rm -f "$_MS_ERR"
                fi
            fi
        else
            log "数据库已有数据，跳过安装。"
        fi
    fi

    # v5.0: 语言包安装移至此处，IS_AUTO_INSTALL 分支外
    # 菜单 11 重试时也会执行
    # v6.2: Multisite 模式下所有 WP-CLI 命令需加 --url 指定主站，避免 "Site not found" 错误
    local _WP_URL_FLAG=()
    [[ "$MS_TYPE" != "single" && -n "$URL" ]] && _WP_URL_FLAG=("--url=${URL}")

    if [[ -n "$LOCALE" && "$LOCALE" != "en_US" ]]; then
        info "安装语言包: ${LOCALE}..."
        "${WP_CMD[@]}" language core install   "$LOCALE" "${_WP_URL_FLAG[@]}" 2>/dev/null || true
        "${WP_CMD[@]}" language theme  install --all "$LOCALE" "${_WP_URL_FLAG[@]}" 2>/dev/null || true
        "${WP_CMD[@]}" language plugin install --all "$LOCALE" "${_WP_URL_FLAG[@]}" 2>/dev/null || true
        "${WP_CMD[@]}" option update WPLANG "$LOCALE" "${_WP_URL_FLAG[@]}" || true
        if [[ -n "$ADMIN" ]]; then
            local ADMIN_ID
            ADMIN_ID=$("${WP_CMD[@]}" user get "$ADMIN" --field=ID "${_WP_URL_FLAG[@]}" 2>/dev/null || echo "1")
            "${WP_CMD[@]}" user meta update "$ADMIN_ID" locale "$LOCALE" "${_WP_URL_FLAG[@]}" 2>/dev/null || true
        fi
        log "界面语言已设为 ${LOCALE}"
    fi

    info "修复文件权限..."
    dc "$DIR" exec -T wordpress chown -R www-data:www-data /var/www/html/wp-content || true

    info "配置 Redis 插件..."
    if "${WP_CMD[@]}" plugin is-installed redis-cache "${_WP_URL_FLAG[@]}" &>/dev/null; then
        "${WP_CMD[@]}" plugin activate redis-cache "${_WP_URL_FLAG[@]}" || warn "Redis 插件激活失败"
    else
        "${WP_CMD[@]}" plugin install redis-cache --activate "${_WP_URL_FLAG[@]}" || warn "Redis 插件安装失败"
    fi

    info "探测 Redis 连通性..."
    local REDIS_HOST_VAL
    REDIS_HOST_VAL=$(env_get "$DIR/.env" "REDIS_HOST")
    local PROBE="\$c=@fsockopen('${REDIS_HOST_VAL}',6379,\$e,\$s,5);if(\$c){fclose(\$c);exit(0);}exit(1);"
    if dc "$DIR" exec -T wordpress php -r "$PROBE" 2>/dev/null; then
        "${WP_CMD[@]}" redis enable "${_WP_URL_FLAG[@]}" && log "Redis 对象缓存已启用！" || warn "redis enable 失败"
    else
        warn "无法连接 Redis (${REDIS_HOST_VAL}:6379)，跳过启用"
    fi
}

# ════════════════════════════════════════════════════════
# 仓库部署
# ════════════════════════════════════════════════════════
cmd_registry() {
    header "部署私有镜像仓库"
    local WG_IP
    WG_IP=$(get_wg_ip)

    read -rp "仓库监听端口 [默认: 5000]: " REG_PORT || true
    REG_PORT="${REG_PORT:-5000}"
    [[ "$REG_PORT" =~ ^[0-9]+$ ]] || error "无效端口"
    (( REG_PORT >= 1 && REG_PORT <= 65535 )) || error "端口范围必须在 1-65535 之间"
    check_port "$WG_IP" "$REG_PORT"

    read -rp "仓库认证用户名 [默认: wpregistry]: " REG_USER || true
    REG_USER="${REG_USER:-wpregistry}"
    local REG_PASS=""
    read_secret "仓库认证密码 [留空随机生成]: " REG_PASS
    if [[ -z "$REG_PASS" ]]; then
        REG_PASS=$(LC_ALL=C tr -dc 'A-Za-z0-9' < /dev/urandom 2>/dev/null | head -c 20; true)
        [[ ${#REG_PASS} -eq 20 ]] || error "随机密码生成异常（${#REG_PASS}/20），请检查 /dev/urandom"
        info "已生成随机密码: ${REG_PASS}"
    fi

    mkdir -p "$REGISTRY_DIR"/{data,auth,certs}

    local HTPASSWD_TMP; HTPASSWD_TMP=$(mktemp)
    trap 'rm -f "$HTPASSWD_TMP"' EXIT
    local HTPASSWD_OK=false
    # [fix] v6.7: 原来用 -Bbn "$REG_USER" "$REG_PASS"，密码作为命令行参数，
    # 执行瞬间同机其他用户用 ps/proc 能看到。改用 -Bin（从 stdin 读密码，
    # 不回显、不校验）+ 管道传参，密码不再出现在进程参数列表里。
    if command -v htpasswd &>/dev/null; then
        printf '%s' "$REG_PASS" | htpasswd -Bin "$REG_USER" > "$HTPASSWD_TMP" && HTPASSWD_OK=true
    fi
    if [[ "$HTPASSWD_OK" != "true" ]]; then
        if printf '%s' "$REG_PASS" | docker run --rm -i --entrypoint htpasswd \
                httpd:alpine -Bin "$REG_USER" \
                > "$HTPASSWD_TMP" 2>/dev/null; then
            HTPASSWD_OK=true
        fi
    fi
    if [[ "$HTPASSWD_OK" != "true" ]] || [[ ! -s "$HTPASSWD_TMP" ]]; then
        rm -f "$HTPASSWD_TMP"
        error "无法生成 htpasswd，请安装 apache2-utils 或确保 Docker 可用"
    fi
    mv "$HTPASSWD_TMP" "$REGISTRY_DIR/auth/htpasswd"
    chmod 600 "$REGISTRY_DIR/auth/htpasswd"
    rm -f "$HTPASSWD_TMP"
    trap - EXIT

    cat > "$REGISTRY_DIR/docker-compose.yml" <<YAML
services:
  registry:
    image: registry:2
    restart: unless-stopped
    network_mode: host
    environment:
      REGISTRY_HTTP_ADDR:               ${WG_IP}:${REG_PORT}
      REGISTRY_AUTH:                    htpasswd
      REGISTRY_AUTH_HTPASSWD_REALM:     "WP Registry"
      REGISTRY_AUTH_HTPASSWD_PATH:      /auth/htpasswd
      REGISTRY_STORAGE_FILESYSTEM_ROOTDIRECTORY: /data
      REGISTRY_STORAGE_DELETE_ENABLED: "true"
    volumes:
      - ./data:/data
      - ./auth:/auth
YAML

    cat > "$REGISTRY_DIR/.env" <<EOF
REGISTRY_HOST=${WG_IP}:${REG_PORT}
REGISTRY_USER=${REG_USER}
REGISTRY_PASS=${REG_PASS}
EOF
    chmod 600 "$REGISTRY_DIR/.env"
    docker compose -f "$REGISTRY_DIR/docker-compose.yml" up -d || error "仓库启动失败"

    info "等待仓库服务就绪..."
    local _RETRIES=20
    until curl -sf -u "${REG_USER}:${REG_PASS}" \
            "http://${WG_IP}:${REG_PORT}/v2/" &>/dev/null; do
        sleep 2; _RETRIES=$(( _RETRIES - 1 ))
        [[ $_RETRIES -le 0 ]] && error "仓库服务未能在预期时间内就绪，请检查容器日志"
    done

    local REGISTRY_ADDR="${WG_IP}:${REG_PORT}"   # 补充定义
    # 确保本机 Docker 信任该仓库
    _ensure_insecure_registry "${REGISTRY_ADDR}"
    log "私有仓库已部署！"
    echo -e "  仓库地址: \e[33m${REGISTRY_ADDR}\e[0m"
    echo -e "  用户名:   \e[32m${REG_USER}\e[0m"
    echo -e "  密码:     \e[32m${REG_PASS}\e[0m"
    echo -e "  \e[36m工作节点 .env 中填写 REGISTRY_HOST=${REGISTRY_ADDR}\e[0m"
}

# ════════════════════════════════════════════════════════
# 主节点初始化
# ════════════════════════════════════════════════════════
cmd_master_init() {
    header "主节点初始化（全自动建站）"

    # v6.0: 实例选择
    local DIR INST
    _resolve_instance DIR INST
    info "实例: ${INST}  目录: ${DIR}"

    info "--- 站点配置 ---"
    read -rp "站点 URL（如 https://example.com）: " WP_URL || true
    [[ -n "$WP_URL" ]] || error "URL 不能为空"
    read -rp "站点名称 [默认: My WordPress]: " WP_TITLE || true
    WP_TITLE="${WP_TITLE:-My WordPress}"
    read -rp "安装语言 [默认: zh_CN]: " WP_LOCALE || true
    WP_LOCALE="${WP_LOCALE:-zh_CN}"
    read -rp "管理员用户名 [默认: wpadmin]: " WP_ADMIN || true
    WP_ADMIN="${WP_ADMIN:-wpadmin}"
    local WP_PASS=""
    read_secret "管理员密码 [留空随机生成]: " WP_PASS
    if [[ -z "$WP_PASS" ]]; then
        WP_PASS=$(LC_ALL=C tr -dc 'A-Za-z0-9!@#%^&*()' < /dev/urandom 2>/dev/null | head -c 16; true)
        [[ ${#WP_PASS} -eq 16 ]] || error "随机密码生成异常（${#WP_PASS}/16），请检查 /dev/urandom"
        info "已生成随机密码: ${WP_PASS}"
    fi
    read -rp "管理员邮箱 [默认: admin@example.com]: " WP_EMAIL || true
    WP_EMAIL="${WP_EMAIL:-admin@example.com}"

    # v6.0: Multisite 配置
    info "--- Multisite（可选）---"
    local WP_MULTISITE_TYPE="single" WP_MULTISITE_DOMAIN=""
    read -rp "启用 WordPress Multisite？[y/N]: " _MS_ENABLE || true
    if [[ "${_MS_ENABLE,,}" == "y" ]]; then
        echo "  1. 子目录模式（/site1 /site2）"
        echo "  2. 子域名模式（site1.example.com）"
        read -rp "选择 [默认: 1]: " _MS_MODE || true
        if [[ "${_MS_MODE:-1}" == "2" ]]; then
            WP_MULTISITE_TYPE="subdomain"
            read -rp "根域名（如 example.com）: " WP_MULTISITE_DOMAIN || true
            [[ -n "$WP_MULTISITE_DOMAIN" ]] || error "子域名模式必须填写根域名"
            info "  ⚠ 子域名模式需要 DNS 通配符解析 *.${WP_MULTISITE_DOMAIN} → 服务器IP"
        else
            WP_MULTISITE_TYPE="subdirectory"
        fi
        info "  Multisite 模式: ${WP_MULTISITE_TYPE}"
    fi

    # v6.6: Redis 全页缓存开关
    info "--- Redis 全页缓存（可选，默认关闭）---"
    local WP_PAGE_CACHE_ENABLED="false"
    read -rp "启用 Redis 全页缓存？[y/N]: " _PC_ENABLE || true
    [[ "${_PC_ENABLE,,}" == "y" ]] && WP_PAGE_CACHE_ENABLED="true"

    info "--- 数据库 ---"
    read -rp "MariaDB WireGuard IP: " DB_HOST || true
    [[ -n "$DB_HOST" ]] || error "数据库 IP 不能为空"
    DB_HOST="${DB_HOST%%:*}"
    read -rp "数据库名 [默认: ${INST}]: " DB_NAME || true; DB_NAME="${DB_NAME:-${INST}}"
    read -rp "数据库用户名 [默认: wpuser]: " DB_USER || true; DB_USER="${DB_USER:-wpuser}"
    local DB_PW=""
    read_secret "数据库密码: " DB_PW
    [[ -n "$DB_PW" ]] || error "数据库密码不能为空"

    info "--- Redis ---"
    read -rp "Redis WireGuard IP [默认同数据库 ${DB_HOST}]: " REDIS_HOST || true
    REDIS_HOST="${REDIS_HOST:-$DB_HOST}"; REDIS_HOST="${REDIS_HOST%%:*}"
    local REDIS_PW=""
    read_secret "Redis 密码: " REDIS_PW
    [[ -n "$REDIS_PW" ]] || error "Redis 密码不能为空"

    info "--- 私有镜像仓库 ---"
    read -rp "Registry 地址（如 10.10.0.1:5000）: " REGISTRY_HOST || true
    [[ -n "$REGISTRY_HOST" ]] || error "Registry 地址不能为空"

    info "--- Cloudflare（可选）---"
    read -rp "CF Zone ID（留空跳过）: " CF_ZONE_ID || true; CF_ZONE_ID="${CF_ZONE_ID:-}"
    local CF_TOKEN=""
    [[ -n "$CF_ZONE_ID" ]] && read_secret "CF API Token: " CF_TOKEN

    read -rp "WordPress 监听端口 [默认: 80]: " WP_PORT || true
    WP_PORT="${WP_PORT:-80}"
    [[ "$WP_PORT" =~ ^[0-9]+$ ]] && (( WP_PORT >= 1 && WP_PORT <= 65535 )) || { WP_PORT=80; warn "无效端口，使用默认 80"; }

    local WG_IP
    WG_IP=$(get_wg_ip)
    log "WireGuard IP: ${WG_IP}"

    info "检查关键服务连通性..."
    check_network "${DB_HOST}:3306" "${REDIS_HOST}:6379" || true
    check_port "$WG_IP" "$WP_PORT"

    info "生成 WordPress Salts..."
    local S_AUTH_KEY S_SECURE_AUTH_KEY S_LOGGED_IN_KEY S_NONCE_KEY
    local S_AUTH_SALT S_SECURE_AUTH_SALT S_LOGGED_IN_SALT S_NONCE_SALT
    S_AUTH_KEY=$(_gen_salt); S_SECURE_AUTH_KEY=$(_gen_salt)
    S_LOGGED_IN_KEY=$(_gen_salt); S_NONCE_KEY=$(_gen_salt)
    S_AUTH_SALT=$(_gen_salt); S_SECURE_AUTH_SALT=$(_gen_salt)
    S_LOGGED_IN_SALT=$(_gen_salt); S_NONCE_SALT=$(_gen_salt)

    mkdir -p "$DIR"/{data/uploads,data/cache,conf,logs}
    # [fix] v6.4: 预先 touch 出空文件，避免 Docker 在 bind mount 源文件
    # 不存在时自动建出同名目录，导致容器内路径变成目录而非文件
    touch "$DIR/conf/wp-config.php"

    {
        printf 'WORDPRESS_DB_PASSWORD=%s
' "${DB_PW}"
        printf 'WORDPRESS_DB_NAME=%s
'     "${DB_NAME}"
        printf 'WORDPRESS_DB_USER=%s
'     "${DB_USER}"
        printf 'DB_HOST=%s
'               "${DB_HOST}"
        printf 'REDIS_HOST=%s
'            "${REDIS_HOST}"
        printf 'REDIS_PW=%s
'              "${REDIS_PW}"
        printf 'WG_IP=%s
'                 "${WG_IP}"
        printf 'WP_PORT=%s
'               "${WP_PORT}"
        printf 'WP_SITEURL_FALLBACK=%s
'   "${WP_URL}"
        printf 'REGISTRY_HOST=%s
'         "${REGISTRY_HOST}"
        printf 'IMAGE_TAG=latest
'
        printf 'NODE_ROLE=master
'
        printf 'CF_ZONE_ID=%s
'            "${CF_ZONE_ID}"
        printf 'CF_TOKEN=%s
'              "${CF_TOKEN}"
        printf 'WP_INSTANCE=%s
'           "${INST}"
        printf 'WP_MULTISITE_TYPE=%s
'     "${WP_MULTISITE_TYPE}"
        printf 'WP_MULTISITE_DOMAIN=%s
'   "${WP_MULTISITE_DOMAIN}"
        printf 'PAGE_CACHE_ENABLED=%s
'   "${WP_PAGE_CACHE_ENABLED}"
        printf 'WP_AUTH_KEY=%s
'           "${S_AUTH_KEY}"
        printf 'WP_SECURE_AUTH_KEY=%s
'    "${S_SECURE_AUTH_KEY}"
        printf 'WP_LOGGED_IN_KEY=%s
'      "${S_LOGGED_IN_KEY}"
        printf 'WP_NONCE_KEY=%s
'          "${S_NONCE_KEY}"
        printf 'WP_AUTH_SALT=%s
'          "${S_AUTH_SALT}"
        printf 'WP_SECURE_AUTH_SALT=%s
'   "${S_SECURE_AUTH_SALT}"
        printf 'WP_LOGGED_IN_SALT=%s
'     "${S_LOGGED_IN_SALT}"
        printf 'WP_NONCE_SALT=%s
'         "${S_NONCE_SALT}"
    } > "$DIR/.env"
    chmod 600 "$DIR/.env"

    _write_nginx_main_conf    "$DIR/conf/nginx.conf"
    _write_nginx_wp_conf      "$DIR/conf/nginx-wp.conf" "$WP_MULTISITE_TYPE" "$WP_MULTISITE_DOMAIN"
    _sed_nginx_wp_conf        "$DIR/conf/nginx-wp.conf" "$WG_IP" "$WP_PORT"
    _write_php_uploads_ini    "$DIR/conf/php-uploads.ini"
    _write_opcache_ini        "$DIR/conf/opcache.ini"
    _write_php_fpm_www_conf   "$DIR/conf/php-fpm-www.conf"
    _write_supervisord_conf   "$DIR/conf/supervisord.conf"
    # v6.6: 页面缓存 drop-in 文件内容本身不区分开关状态，无条件写出，
    # 实际是否生效由 wp-config-extra.php 里的 WP_PAGE_CACHE_ENABLED 常量控制
    _write_advanced_cache_php        "$DIR/conf/advanced-cache.php"
    _write_pagecache_purge_mu_plugin "$DIR/conf/pagecache-purge.php"
    local R2_KEY R2_SECRET R2_BUCKET R2_DOMAIN R2_ENDPOINT
    R2_KEY=$(env_get "$DIR/.env" "R2_ACCESS_KEY" 2>/dev/null || true)
    R2_SECRET=$(env_get "$DIR/.env" "R2_SECRET_KEY" 2>/dev/null || true)
    R2_BUCKET=$(env_get "$DIR/.env" "R2_BUCKET" 2>/dev/null || true)
    R2_DOMAIN=$(env_get "$DIR/.env" "R2_DOMAIN" 2>/dev/null || true)
    R2_ENDPOINT=$(env_get "$DIR/.env" "R2_ENDPOINT" 2>/dev/null || true)
    _write_wp_config_extra    "$DIR/conf/wp-config-extra.php" "master" \
        "$S_AUTH_KEY" "$S_SECURE_AUTH_KEY" "$S_LOGGED_IN_KEY" "$S_NONCE_KEY" \
        "$S_AUTH_SALT" "$S_SECURE_AUTH_SALT" "$S_LOGGED_IN_SALT" "$S_NONCE_SALT" \
        "$WP_MULTISITE_TYPE" "$WP_MULTISITE_DOMAIN" \
        "$R2_KEY" "$R2_SECRET" "$R2_BUCKET" "$R2_DOMAIN" "$R2_ENDPOINT" \
        "$WP_PAGE_CACHE_ENABLED"
    _write_init_dockerfile    "$DIR"
    _write_entrypoint_script  "$DIR/entrypoint.sh"
    _write_init_compose       "$DIR" "$INST"
    _register_node "$WG_IP"

    info "构建初始化镜像并启动..."
    dc "$DIR" build --pull || error "镜像构建失败"
    dc "$DIR" up -d       || error "容器启动失败"

    _setup_plugins "$DIR" "true"         "$WP_URL" "$WP_TITLE" "$WP_ADMIN" "$WP_PASS" "$WP_EMAIL" "$WP_LOCALE"         "$WP_MULTISITE_TYPE" "$WP_MULTISITE_DOMAIN"         || warn "插件配置未完全成功，可通过菜单 11 重试"

    log "主节点初始化完成！"
    echo -e "  实例:     \e[36m${INST}\e[0m"
    echo -e "  内网访问: \e[33mhttp://${WG_IP}\e[0m"
    echo -e "  站点:     \e[33m${WP_URL}\e[0m"
    echo -e "  账号:     \e[32m${WP_ADMIN}\e[0m / \e[32m${WP_PASS}\e[0m"
    if [[ "$WP_MULTISITE_TYPE" != "single" ]]; then
        echo -e "  Multisite: \e[35m${WP_MULTISITE_TYPE}\e[0m"
        [[ -n "$WP_MULTISITE_DOMAIN" ]] && echo -e "  根域名:   \e[35m${WP_MULTISITE_DOMAIN}\e[0m"
    fi
    echo ""
    _c "1;33" ">>> WP-Cron 定时任务提示 <<<"
    echo -e "  内置 WP-Cron 已禁用，请在\e[33m某一台节点宿主机\e[0m添加以下 crontab："
    echo -e "  \e[36m*/5 * * * * docker exec \$(docker ps -qf name=wordpress) wp --allow-root cron event run --due-now --path=/var/www/html >/dev/null 2>&1\e[0m"
    echo -e "  或使用 crontab -e 添加，建议选主节点执行。"
    echo ""
    echo -e "  \e[36m在后台完成主题/插件配置后，执行菜单 3（打包推送）分发到工作节点。\e[0m"
}

# ════════════════════════════════════════════════════════
# 主节点打包推送
# ════════════════════════════════════════════════════════
cmd_push() {
    header "打包推送镜像到私有仓库"

    # v6.0: 实例选择
    local DIR INST
    _resolve_instance DIR INST
    [[ -f "$DIR/.env" ]] || error "未找到 .env：${DIR}，请先执行主节点初始化"
    info "实例: ${INST}"

    local REGISTRY_HOST WG_IP
    REGISTRY_HOST=$(env_get "$DIR/.env" "REGISTRY_HOST")
    WG_IP=$(env_get "$DIR/.env" "WG_IP")
    [[ -n "$REGISTRY_HOST" ]] || error ".env 中缺少 REGISTRY_HOST"
    [[ -n "$WG_IP" ]]         || WG_IP=$(get_wg_ip)

    local IMAGE_TAG="v$(date +%Y%m%d%H%M)"
    # v6.0: 镜像名以实例名为命名空间
    local IMAGE_BASE="${REGISTRY_HOST}/wordpress-${INST}"

    local CID
    CID=$(docker compose -f "$DIR/docker-compose.yml" --env-file "$DIR/.env" ps -q wordpress 2>/dev/null || true)
    [[ -n "$CID" ]] || error "wordpress 容器未运行，请先启动主节点（菜单 8）再推送"

    local WP_VER
    WP_VER=$(docker exec "$CID" \
        grep -oP "(?<=wp_version = ')[^']+" /var/www/html/wp-includes/version.php 2>/dev/null) \
        || WP_VER="未知"
    local THEMES_COUNT PLUGINS_COUNT
    THEMES_COUNT=$(docker exec "$CID" \
        sh -c 'find /var/www/html/wp-content/themes -maxdepth 1 -mindepth 1 -type d 2>/dev/null | wc -l' \
        2>/dev/null || echo "?")
    PLUGINS_COUNT=$(docker exec "$CID" \
        sh -c 'find /var/www/html/wp-content/plugins -maxdepth 1 -mindepth 1 -type d 2>/dev/null | wc -l' \
        2>/dev/null || echo "?")

    echo ""
    echo "  WordPress 版本: ${WP_VER}"
    echo "  主题数量:       ${THEMES_COUNT} 个"
    echo "  插件数量:       ${PLUGINS_COUNT} 个"
    echo "  镜像 tag:       ${IMAGE_TAG}"
    echo ""
    read -rp "确认打包推送？[y/N]: " CONFIRM || true
    [[ "${CONFIRM,,}" == "y" ]] || { info "已取消"; return; }

    local BUILD_DIR
    BUILD_DIR=$(mktemp -d /tmp/wp-build-XXXXXX)

    local _PUSH_CLEANUP_DONE=false
    _push_cleanup() {
        [[ "$_PUSH_CLEANUP_DONE" == "true" ]] && return
        _PUSH_CLEANUP_DONE=true
        rm -rf "$BUILD_DIR"
    }
    # [fix] 原来 trap RETURN ERR：
    #   - RETURN 只在函数正常 return 时触发，error() 调用 exit 1 会绕过它
    #   - 脚本无 set -E（errtrace），ERR trap 在函数内不继承，同样不可靠
    # 改用 EXIT trap：无论正常返回还是 error() → exit 1 都会触发，
    # 函数末尾显式调用并重置，避免 trap 泄漏到后续菜单操作。
    trap '_push_cleanup' EXIT

    info "从容器导出 WordPress 核心文件..."
    mkdir -p "$BUILD_DIR/wp-core" "$BUILD_DIR/wp-content/themes" "$BUILD_DIR/wp-content/plugins"

    docker cp "${CID}:/var/www/html/." "$BUILD_DIR/wp-core/"
    rm -rf "$BUILD_DIR/wp-core/wp-content" \
           "$BUILD_DIR/wp-core/wp-config.php" \
           "$BUILD_DIR/wp-core/wp-config-sample.php"

    info "导出主题和插件..."
    docker cp "${CID}:/var/www/html/wp-content/themes/."  "$BUILD_DIR/wp-content/themes/"
    docker cp "${CID}:/var/www/html/wp-content/plugins/." "$BUILD_DIR/wp-content/plugins/"
    rm -rf "$BUILD_DIR/wp-content/uploads" \
           "$BUILD_DIR/wp-content/cache"

    # v5.0: 从主节点 .env 读取 salts，打包进镜像内的 wp-config-extra.php
    # 确保所有工作节点与主节点使用相同 salts，cookie 互认
    info "读取 Salts 并生成配置文件..."
    local P_AUTH_KEY P_SECURE_AUTH_KEY P_LOGGED_IN_KEY P_NONCE_KEY
    local P_AUTH_SALT P_SECURE_AUTH_SALT P_LOGGED_IN_SALT P_NONCE_SALT
    P_AUTH_KEY=$(env_get          "$DIR/.env" "WP_AUTH_KEY")
    P_SECURE_AUTH_KEY=$(env_get   "$DIR/.env" "WP_SECURE_AUTH_KEY")
    P_LOGGED_IN_KEY=$(env_get     "$DIR/.env" "WP_LOGGED_IN_KEY")
    P_NONCE_KEY=$(env_get         "$DIR/.env" "WP_NONCE_KEY")
    P_AUTH_SALT=$(env_get         "$DIR/.env" "WP_AUTH_SALT")
    P_SECURE_AUTH_SALT=$(env_get  "$DIR/.env" "WP_SECURE_AUTH_SALT")
    P_LOGGED_IN_SALT=$(env_get    "$DIR/.env" "WP_LOGGED_IN_SALT")
    P_NONCE_SALT=$(env_get        "$DIR/.env" "WP_NONCE_SALT")

    # v6.0: 读取 Multisite 配置
    local P_MS_TYPE P_MS_DOMAIN
    P_MS_TYPE=$(env_get "$DIR/.env" "WP_MULTISITE_TYPE");   P_MS_TYPE="${P_MS_TYPE:-single}"
    P_MS_DOMAIN=$(env_get "$DIR/.env" "WP_MULTISITE_DOMAIN"); P_MS_DOMAIN="${P_MS_DOMAIN:-}"

    # v6.6: 读取页面缓存开关，主/工作节点镜像都传，确保全节点开关一致
    local P_PAGE_CACHE_ENABLED
    P_PAGE_CACHE_ENABLED=$(env_get "$DIR/.env" "PAGE_CACHE_ENABLED" 2>/dev/null || true)
    [[ "$P_PAGE_CACHE_ENABLED" == "true" ]] || P_PAGE_CACHE_ENABLED="false"

    if [[ -z "$P_AUTH_KEY" ]]; then
        warn ".env 中未找到 Salts（旧版部署？），将生成新 Salts 并写回 .env"
        P_AUTH_KEY=$(_gen_salt);        P_SECURE_AUTH_KEY=$(_gen_salt)
        P_LOGGED_IN_KEY=$(_gen_salt);   P_NONCE_KEY=$(_gen_salt)
        P_AUTH_SALT=$(_gen_salt);       P_SECURE_AUTH_SALT=$(_gen_salt)
        P_LOGGED_IN_SALT=$(_gen_salt);  P_NONCE_SALT=$(_gen_salt)
        {
            printf 'WP_AUTH_KEY=%s
'          "${P_AUTH_KEY}"
            printf 'WP_SECURE_AUTH_KEY=%s
'   "${P_SECURE_AUTH_KEY}"
            printf 'WP_LOGGED_IN_KEY=%s
'     "${P_LOGGED_IN_KEY}"
            printf 'WP_NONCE_KEY=%s
'         "${P_NONCE_KEY}"
            printf 'WP_AUTH_SALT=%s
'         "${P_AUTH_SALT}"
            printf 'WP_SECURE_AUTH_SALT=%s
'  "${P_SECURE_AUTH_SALT}"
            printf 'WP_LOGGED_IN_SALT=%s
'    "${P_LOGGED_IN_SALT}"
            printf 'WP_NONCE_SALT=%s
'        "${P_NONCE_SALT}"
        } >> "$DIR/.env"
        local R2_KEY R2_SECRET R2_BUCKET R2_DOMAIN R2_ENDPOINT
        R2_KEY=$(env_get "$DIR/.env" "R2_ACCESS_KEY" 2>/dev/null || true)
        R2_SECRET=$(env_get "$DIR/.env" "R2_SECRET_KEY" 2>/dev/null || true)
        R2_BUCKET=$(env_get "$DIR/.env" "R2_BUCKET" 2>/dev/null || true)
        R2_DOMAIN=$(env_get "$DIR/.env" "R2_DOMAIN" 2>/dev/null || true)
        R2_ENDPOINT=$(env_get "$DIR/.env" "R2_ENDPOINT" 2>/dev/null || true)
        _write_wp_config_extra "$DIR/conf/wp-config-extra.php" "master" \
            "$P_AUTH_KEY" "$P_SECURE_AUTH_KEY" "$P_LOGGED_IN_KEY" "$P_NONCE_KEY" \
            "$P_AUTH_SALT" "$P_SECURE_AUTH_SALT" "$P_LOGGED_IN_SALT" "$P_NONCE_SALT" \
            "$P_MS_TYPE" "$P_MS_DOMAIN" \
            "$R2_KEY" "$R2_SECRET" "$R2_BUCKET" "$R2_DOMAIN" "$R2_ENDPOINT" \
            "$P_PAGE_CACHE_ENABLED"
        warn "主节点容器需重启后 salts 才会生效：菜单 10 → 重启节点"
    fi

    mkdir -p "$BUILD_DIR/conf"
    _write_nginx_main_conf   "$BUILD_DIR/conf/nginx.conf"
    # v6.0: 镜像内 nginx-wp.conf 含 Multisite rewrite/server_name，保留 IP 占位符
    _write_nginx_wp_conf     "$BUILD_DIR/conf/nginx-wp.conf" "$P_MS_TYPE" "$P_MS_DOMAIN"
    _write_php_uploads_ini   "$BUILD_DIR/conf/php-uploads.ini"
    _write_opcache_ini       "$BUILD_DIR/conf/opcache.ini"
    _write_php_fpm_www_conf  "$BUILD_DIR/conf/php-fpm-www.conf"
    _write_supervisord_conf  "$BUILD_DIR/conf/supervisord.conf"
    # v6.6: 页面缓存 drop-in 文件，内容不区分开关状态，随镜像无条件打包
    _write_advanced_cache_php        "$BUILD_DIR/conf/advanced-cache.php"
    _write_pagecache_purge_mu_plugin "$BUILD_DIR/conf/pagecache-purge.php"
    # v6.0: worker 角色 + 统一 salts + Multisite 常量
    # 注意: worker 节点不进 wp-admin、不跑 Test Connection，刻意不传 R2 凭证
    # ($13-$17 留空)，避免凭证扩散到所有 worker 节点，减少泄露面
    # v6.6: 但页面缓存开关（$18）主/工作节点都传，全节点开关必须一致
    _write_wp_config_extra   "$BUILD_DIR/conf/wp-config-extra.php" "worker" \
        "$P_AUTH_KEY" "$P_SECURE_AUTH_KEY" "$P_LOGGED_IN_KEY" "$P_NONCE_KEY" \
        "$P_AUTH_SALT" "$P_SECURE_AUTH_SALT" "$P_LOGGED_IN_SALT" "$P_NONCE_SALT" \
        "$P_MS_TYPE" "$P_MS_DOMAIN" \
        "" "" "" "" "" \
        "$P_PAGE_CACHE_ENABLED"
    _write_entrypoint_script "$BUILD_DIR/entrypoint.sh"
    _write_master_dockerfile "$BUILD_DIR"

    info "构建镜像: ${IMAGE_BASE}:${IMAGE_TAG} ..."
    docker build --pull --no-cache \
        -t "${IMAGE_BASE}:${IMAGE_TAG}" \
        -t "${IMAGE_BASE}:latest" \
        "$BUILD_DIR" \
    || error "镜像构建失败"

    local REG_USER REG_PASS
    if [[ -f "$REGISTRY_DIR/.env" ]]; then
        REG_USER=$(env_get "$REGISTRY_DIR/.env" "REGISTRY_USER")
        REG_PASS=$(env_get "$REGISTRY_DIR/.env" "REGISTRY_PASS")
    else
        read -rp "仓库用户名: " REG_USER || true
        read_secret "仓库密码: " REG_PASS
    fi
    # 确保本机 Docker 信任私有仓库（仓库机可能独立部署）
    _ensure_insecure_registry "$REGISTRY_HOST"
    docker login "$REGISTRY_HOST" -u "$REG_USER" --password-stdin <<<"$REG_PASS" \
    || error "仓库登录失败"

    info "推送 ${IMAGE_BASE}:${IMAGE_TAG} ..."
    docker push "${IMAGE_BASE}:${IMAGE_TAG}" || error "推送失败"
    docker push "${IMAGE_BASE}:latest"       || error "推送 latest 失败"

    # [fix] v6.7: docker login 会把仓库密码以 base64（非加密）形式写进
    # ~/.docker/config.json 并长期保留；操作完成后登出，缩短凭证残留窗口
    docker logout "$REGISTRY_HOST" &>/dev/null || true

    if grep -q '^IMAGE_TAG=' "$DIR/.env"; then
        sed -i "s|^IMAGE_TAG=.*|IMAGE_TAG=${IMAGE_TAG}|" "$DIR/.env"
    else
        echo "IMAGE_TAG=${IMAGE_TAG}" >> "$DIR/.env"
    fi

    info "清理本地旧镜像（保留最近 5 个）..."
    # [fix] 原来用 {{.ID}} 再 docker rmi <id>：同一 ID 被多个 tag 引用时报
    # "image is referenced in multiple repositories"，xargs 链中断。
    # 改用 Repository:Tag 格式，精确删除指定 tag，不影响其他引用。
    docker images "${IMAGE_BASE}" --format "{{.Repository}}:{{.Tag}}" \
        | grep -v ':latest$' | sort -r | tail -n +6 \
        | xargs -r docker rmi 2>/dev/null || true

    log "推送完成！"
    echo -e "  实例:    \e[36m${INST}\e[0m"
    echo -e "  镜像:    \e[32m${IMAGE_BASE}:${IMAGE_TAG}\e[0m"
    echo -e "  WP 版本: \e[36m${WP_VER}\e[0m"
    echo -e "  \e[36m工作节点执行菜单 4（拉取部署/更新），选择相同实例名即可。\e[0m"

    # 正常结束：主动清理并重置 trap，避免 EXIT trap 泄漏到后续菜单操作
    _push_cleanup
    trap - EXIT
}

# ════════════════════════════════════════════════════════
# 工作节点拉取部署 / 更新
# ════════════════════════════════════════════════════════
cmd_pull_deploy() {
    header "工作节点拉取部署 / 更新"

    # v6.0: 实例选择
    local DIR INST
    _resolve_instance DIR INST
    info "实例: ${INST}  目录: ${DIR}"

    local IS_FIRST=false
    local DB_HOST="" DB_NAME="" DB_USER="" DB_PW="" REDIS_HOST="" REDIS_PW=""
    local WP_URL="" WP_PORT="80"
    local REGISTRY_HOST="" CF_ZONE_ID="" CF_TOKEN="" WG_IP=""

    if [[ ! -f "$DIR/.env" ]]; then
        IS_FIRST=true
        info "未检测到 .env，进入首次部署配置..."

        info "--- 数据库 ---"
        read -rp "MariaDB WireGuard IP: " DB_HOST || true
        [[ -n "$DB_HOST" ]] || error "数据库 IP 不能为空"
        DB_HOST="${DB_HOST%%:*}"
        read -rp "数据库名 [默认: ${INST}]: " DB_NAME || true; DB_NAME="${DB_NAME:-${INST}}"
        read -rp "数据库用户名 [默认: wpuser]: " DB_USER || true; DB_USER="${DB_USER:-wpuser}"
        read_secret "数据库密码: " DB_PW; [[ -n "$DB_PW" ]] || error "数据库密码不能为空"

        info "--- Redis ---"
        read -rp "Redis WireGuard IP [默认: ${DB_HOST}]: " REDIS_HOST || true
        REDIS_HOST="${REDIS_HOST:-$DB_HOST}"; REDIS_HOST="${REDIS_HOST%%:*}"
        read_secret "Redis 密码: " REDIS_PW; [[ -n "$REDIS_PW" ]] || error "Redis 密码不能为空"

        info "--- 站点 ---"
        read -rp "站点 URL（如 https://example.com）: " WP_URL || true
        [[ -n "$WP_URL" ]] || error "URL 不能为空"

        info "--- 私有镜像仓库 ---"
        read -rp "Registry 地址（如 10.10.0.1:5000）: " REGISTRY_HOST || true
        [[ -n "$REGISTRY_HOST" ]] || error "Registry 地址不能为空"

        info "--- Cloudflare（可选）---"
        read -rp "CF Zone ID（留空跳过）: " CF_ZONE_ID || true; CF_ZONE_ID="${CF_ZONE_ID:-}"
        [[ -n "$CF_ZONE_ID" ]] && read_secret "CF API Token: " CF_TOKEN

        read -rp "WordPress 监听端口 [默认: 80]: " WP_PORT || true
        WP_PORT="${WP_PORT:-80}"
        [[ "$WP_PORT" =~ ^[0-9]+$ ]] && (( WP_PORT >= 1 && WP_PORT <= 65535 )) || { WP_PORT=80; warn "无效端口，使用默认 80"; }
        WG_IP=$(get_wg_ip)
        check_port "$WG_IP" "$WP_PORT"
        check_network "${DB_HOST}:3306" "${REDIS_HOST}:6379" || true

        mkdir -p "$DIR"/{data/uploads,data/cache,conf,logs}
    # [fix] v6.4: 预先 touch 出空文件，避免 Docker 在 bind mount 源文件
    # 不存在时自动建出同名目录，导致容器内路径变成目录而非文件
    touch "$DIR/conf/wp-config.php"

        {
            printf 'WORDPRESS_DB_PASSWORD=%s
' "${DB_PW}"
            printf 'WORDPRESS_DB_NAME=%s
'     "${DB_NAME}"
            printf 'WORDPRESS_DB_USER=%s
'     "${DB_USER}"
            printf 'DB_HOST=%s
'               "${DB_HOST}"
            printf 'REDIS_HOST=%s
'            "${REDIS_HOST}"
            printf 'REDIS_PW=%s
'              "${REDIS_PW}"
            printf 'WG_IP=%s
'                 "${WG_IP}"
            printf 'WP_PORT=%s
'               "${WP_PORT}"
            printf 'WP_SITEURL_FALLBACK=%s
'   "${WP_URL}"
            printf 'REGISTRY_HOST=%s
'         "${REGISTRY_HOST}"
            printf 'IMAGE_TAG=latest
'
            printf 'NODE_ROLE=worker
'
            printf 'CF_ZONE_ID=%s
'            "${CF_ZONE_ID}"
            printf 'CF_TOKEN=%s
'              "${CF_TOKEN}"
            printf 'WP_INSTANCE=%s
'           "${INST}"
        } > "$DIR/.env"
        chmod 600 "$DIR/.env"
        _write_worker_compose  "$DIR" "$INST"
        _register_node "$WG_IP"
    fi

    REGISTRY_HOST=$(env_get "$DIR/.env" "REGISTRY_HOST")
    # v6.0: 从 .env 恢复实例名（续部署时）
    local _ENV_INST; _ENV_INST=$(env_get "$DIR/.env" "WP_INSTANCE" 2>/dev/null || true)
    [[ -n "$_ENV_INST" ]] && INST="$_ENV_INST"
    local IMAGE_TAG
    IMAGE_TAG=$(env_get "$DIR/.env" "IMAGE_TAG"); IMAGE_TAG="${IMAGE_TAG:-latest}"
    [[ -n "$REGISTRY_HOST" ]] || error ".env 中缺少 REGISTRY_HOST"

    # 每次都重写 compose，确保镜像名与当前实例一致（修复旧版写死 wordpress-site 的问题）
    # [fix] wp-config.php 尚未生成时必须临时挂载为可写，否则容器内
    # `wp config create` 写入只读 bind mount 会失败，首次部署直接挂掉；
    # 生成完成后必须立即重写回只读，恢复 worker 节点的防篡改边界。
    local _WPCFG_MODE="ro"
    [[ -s "$DIR/conf/wp-config.php" ]] || _WPCFG_MODE="rw"
    _write_worker_compose "$DIR" "$INST" "$_WPCFG_MODE"

    DB_HOST="${DB_HOST:-$(env_get "$DIR/.env" "DB_HOST")}"
    DB_NAME="${DB_NAME:-$(env_get "$DIR/.env" "WORDPRESS_DB_NAME")}"
    DB_USER="${DB_USER:-$(env_get "$DIR/.env" "WORDPRESS_DB_USER")}"
    DB_PW="${DB_PW:-$(env_get "$DIR/.env" "WORDPRESS_DB_PASSWORD")}"

    local REG_USER REG_PASS
    if [[ -f "$REGISTRY_DIR/.env" ]]; then
        REG_USER=$(env_get "$REGISTRY_DIR/.env" "REGISTRY_USER")
        REG_PASS=$(env_get "$REGISTRY_DIR/.env" "REGISTRY_PASS")
    else
        read -rp "仓库用户名: " REG_USER || true
        read_secret "仓库密码: " REG_PASS
    fi
    # 确保本机 Docker 信任私有仓库
    _ensure_insecure_registry "$REGISTRY_HOST"
    docker login "$REGISTRY_HOST" -u "$REG_USER" --password-stdin <<<"$REG_PASS" \
    || error "仓库登录失败"

    # v6.0: 实例命名空间镜像
    local IMAGE_FULL="${REGISTRY_HOST}/wordpress-${INST}:${IMAGE_TAG}"
    info "拉取镜像: ${IMAGE_FULL} ..."
    docker pull "$IMAGE_FULL" || error "镜像拉取失败"

    # [fix] v6.7: 镜像已拉到本地，后续 docker create/cp 导出配置文件不需要仓库
    # 认证，登出以缩短凭证在 ~/.docker/config.json 中的残留窗口
    docker logout "$REGISTRY_HOST" &>/dev/null || true

    # 拉取成功后，将实际使用的 IMAGE_TAG 写回 .env（保持同步）
    if grep -q '^IMAGE_TAG=' "$DIR/.env"; then
        sed -i "s|^IMAGE_TAG=.*|IMAGE_TAG=${IMAGE_TAG}|" "$DIR/.env"
    else
        echo "IMAGE_TAG=${IMAGE_TAG}" >> "$DIR/.env"
    fi

    # v5.0: 从镜像导出 wp-config-extra.php（含 salts）到宿主机 conf/
    # 这是权威版本，不在宿主机重新生成，确保与打包时一致
    info "从镜像导出 wp-config-extra.php（含统一 Salts）..."
    local _TMP_CID
    _TMP_CID=$(docker create "${IMAGE_FULL}" sh 2>/dev/null || true)
    if [[ -n "$_TMP_CID" ]]; then
        docker cp "${_TMP_CID}:/etc/wordpress/wp-config-extra.php" \
            "$DIR/conf/wp-config-extra.php" 2>/dev/null \
        && chmod 600 "$DIR/conf/wp-config-extra.php" \
        && log "  wp-config-extra.php 已导出" \
        || warn "  wp-config-extra.php 导出失败，将使用已有版本"
        docker rm -f "$_TMP_CID" &>/dev/null || true
    else
        warn "无法创建临时容器，跳过 wp-config-extra.php 导出"
    fi

    if [[ ! -s "$DIR/conf/wp-config.php" ]]; then
        info "预启动容器以生成 wp-config.php ..."
        # 上面已按 _WPCFG_MODE=rw 写过 compose；若文件意外不存在则补写一次，同样要 rw
        [[ -f "$DIR/docker-compose.yml" ]] || _write_worker_compose "$DIR" "$INST" "rw"
        dc "$DIR" up -d 2>/dev/null || true

        local RETRIES=20
        while ! dc "$DIR" exec -T wordpress sh -c 'command -v wp' &>/dev/null; do
            sleep 3; RETRIES=$((RETRIES - 1))
            [[ $RETRIES -le 0 ]] && { warn "容器未就绪，跳过 wp-config.php 生成"; break; }
        done

        if dc "$DIR" exec -T wordpress sh -c 'command -v wp' &>/dev/null; then
            local CID
            CID=$(dc "$DIR" ps -q wordpress)
            _wp_config_create_with_extra "$DIR" "$DB_NAME" "$DB_USER" "$DB_PW" "$DB_HOST" \
            && dc "$DIR" exec -T wordpress cp /var/www/html/wp-config.php /tmp/wp-config-out.php \
            && docker cp "${CID}:/tmp/wp-config-out.php" "$DIR/conf/wp-config.php" \
            && chmod 600 "$DIR/conf/wp-config.php" \
            && log "wp-config.php 已生成并导出至 conf/" \
            || warn "wp-config.php 生成失败，请手动创建或稍后重试（菜单 11）"
        fi

        # [fix] 无论生成成功与否，都要把 compose 重写回只读挂载，
        # 防止 worker 节点的 wp-config.php 长期保持可写状态
        _write_worker_compose "$DIR" "$INST" "ro"
    fi

    # v5.0: 统一占位符替换逻辑（主/工作节点一致）
    local _WG_IP_VAL _WP_PORT_VAL
    _WG_IP_VAL=$(env_get "$DIR/.env" "WG_IP")
    _WP_PORT_VAL=$(env_get "$DIR/.env" "WP_PORT"); _WP_PORT_VAL="${_WP_PORT_VAL:-80}"

    # 每次从新镜像导出全部 conf（确保与镜像版本一致，而非沿用旧文件）
    info "从镜像导出配置文件..."
    local _TMP_CID2
    _TMP_CID2=$(docker create "${IMAGE_FULL}" sh 2>/dev/null || true)
    if [[ -n "$_TMP_CID2" ]]; then
        docker cp "${_TMP_CID2}:/etc/nginx/nginx.conf"          "$DIR/conf/nginx.conf"        2>/dev/null && log "  nginx.conf 已导出"        || warn "  nginx.conf 导出失败"
        docker cp "${_TMP_CID2}:/etc/nginx/http.d/default.conf" "$DIR/conf/nginx-wp.conf"     2>/dev/null && log "  nginx-wp.conf 已导出"     || warn "  nginx-wp.conf 导出失败"
        docker cp "${_TMP_CID2}:/usr/local/etc/php/conf.d/uploads.ini"   "$DIR/conf/php-uploads.ini"  2>/dev/null || true
        docker cp "${_TMP_CID2}:/usr/local/etc/php/conf.d/opcache.ini"   "$DIR/conf/opcache.ini"      2>/dev/null || true
        docker cp "${_TMP_CID2}:/usr/local/etc/php-fpm.d/www.conf"       "$DIR/conf/php-fpm-www.conf" 2>/dev/null || true
        docker cp "${_TMP_CID2}:/etc/supervisord.conf"                    "$DIR/conf/supervisord.conf" 2>/dev/null || true
        # v6.6: 页面缓存 drop-in 文件也要导出，_write_worker_compose 会 bind mount 回同样的路径
        docker cp "${_TMP_CID2}:/var/www/html/wp-content/advanced-cache.php"  "$DIR/conf/advanced-cache.php"  2>/dev/null || true
        docker cp "${_TMP_CID2}:/var/www/html/wp-content/mu-plugins/pagecache-purge.php" "$DIR/conf/pagecache-purge.php" 2>/dev/null || true
        docker rm -f "$_TMP_CID2" &>/dev/null || true
    else
        warn "无法创建临时容器，跳过配置文件导出（将使用已有版本）"
    fi

    if [[ -f "$DIR/conf/nginx-wp.conf" ]]; then
        info "替换 nginx-wp.conf 占位符 → ${_WG_IP_VAL}:${_WP_PORT_VAL}"
        _sed_nginx_wp_conf "$DIR/conf/nginx-wp.conf" "$_WG_IP_VAL" "$_WP_PORT_VAL"
    else
        warn "未能获取 nginx-wp.conf，nginx 将使用镜像内默认配置（含占位符）"
    fi

    info "启动 / 更新容器..."
    if [[ "$IS_FIRST" == "true" ]]; then
        dc "$DIR" up -d              || error "容器启动失败"
    else
        dc "$DIR" up -d --force-recreate || error "容器更新失败"
    fi

    info "等待 WordPress 就绪..."
    local RETRIES=30
    while ! dc "$DIR" exec -T wordpress wp --allow-root core is-installed &>/dev/null; do
        sleep 3; RETRIES=$((RETRIES - 1))
        [[ $RETRIES -le 0 ]] && { warn "WordPress 未能在预期时间内就绪"; break; }
    done

    _flush_all_caches "$DIR"

    log "节点部署/更新完成！"
    local WG_IP_SHOW; WG_IP_SHOW=$(env_get "$DIR/.env" "WG_IP")
    echo -e "  镜像版本: \e[32m${IMAGE_TAG}\e[0m"
    echo -e "  内网访问: \e[33mhttp://${WG_IP_SHOW}\e[0m"
    echo -e "  健康检查: \e[36mhttp://${WG_IP_SHOW}:${_WP_PORT_VAL}/health\e[0m"
}

# ════════════════════════════════════════════════════════
# 镜像回滚
# ════════════════════════════════════════════════════════
cmd_rollback() {
    header "镜像回滚"
    local DIR INST
    _resolve_instance DIR INST
    [[ -f "$DIR/.env" ]] || error "未找到 .env：${DIR}"
    local _ENV_INST; _ENV_INST=$(env_get "$DIR/.env" "WP_INSTANCE" 2>/dev/null || true)
    [[ -n "$_ENV_INST" ]] && INST="$_ENV_INST"
    info "实例: ${INST}"

    local REGISTRY_HOST; REGISTRY_HOST=$(env_get "$DIR/.env" "REGISTRY_HOST")
    [[ -n "$REGISTRY_HOST" ]] || error ".env 中缺少 REGISTRY_HOST"

    local REG_USER REG_PASS
    if [[ -f "$REGISTRY_DIR/.env" ]]; then
        REG_USER=$(env_get "$REGISTRY_DIR/.env" "REGISTRY_USER")
        REG_PASS=$(env_get "$REGISTRY_DIR/.env" "REGISTRY_PASS")
    else
        read -rp "仓库用户名: " REG_USER || true
        read_secret "仓库密码: " REG_PASS
    fi

    local TAGS_JSON
    TAGS_JSON=$(curl -sf -u "${REG_USER}:${REG_PASS}" \
        "http://${REGISTRY_HOST}/v2/wordpress-${INST}/tags/list" 2>/dev/null)
    if [[ -z "$TAGS_JSON" ]]; then
        warn "无法从仓库获取标签列表"; return
    fi
    local TAGS
    TAGS=$(echo "$TAGS_JSON" | jq -r '.tags[]' | grep -v '^latest$' | sort -r || true)
    [[ -z "$TAGS" ]] && { warn "仓库中无可用版本"; return; }

    echo ""; echo "可用版本："
    local i=1; local -a TAG_ARR
    while IFS= read -r TAG; do
        echo "  ${i}. ${TAG}"; TAG_ARR+=("$TAG"); i=$((i+1))
    done <<< "$TAGS"

    read -rp "选择版本编号: " TAG_IDX || true
    [[ "$TAG_IDX" =~ ^[0-9]+$ ]] || error "无效编号"
    local SELECTED_TAG="${TAG_ARR[$((TAG_IDX-1))]}"
    [[ -n "$SELECTED_TAG" ]] || error "无效选择"

    warn "将回滚到版本: ${SELECTED_TAG}"
    read -rp "确认？[y/N]: " CONFIRM || true
    [[ "${CONFIRM,,}" == "y" ]] || { info "已取消"; return; }

    _ensure_insecure_registry "$REGISTRY_HOST"
    docker login "$REGISTRY_HOST" -u "$REG_USER" --password-stdin <<<"$REG_PASS" \
    || error "仓库登录失败"
    info "拉取 ${REGISTRY_HOST}/wordpress-${INST}:${SELECTED_TAG} ..."
    docker pull "${REGISTRY_HOST}/wordpress-${INST}:${SELECTED_TAG}" || error "拉取失败"
    docker logout "$REGISTRY_HOST" &>/dev/null || true
    sed -i "s|^IMAGE_TAG=.*|IMAGE_TAG=${SELECTED_TAG}|" "$DIR/.env"
    dc "$DIR" up -d --force-recreate || error "容器重启失败"
    _flush_all_caches "$DIR"
    log "回滚到 ${SELECTED_TAG} 完成！"
}

# ════════════════════════════════════════════════════════
# 运维命令
# ════════════════════════════════════════════════════════
cmd_status() {
    local DIR INST; _resolve_instance DIR INST
    [[ -f "$DIR/docker-compose.yml" ]] || error "未找到编排文件"
    dc "$DIR" ps; echo ""
    local WP_VER
    WP_VER=$(dc "$DIR" exec -T wordpress \
        cat /var/www/html/wp-includes/version.php 2>/dev/null \
        | grep -oP "(?<=wp_version = ')[^']+") || WP_VER="未知"
    echo -e "  实例:           \e[35m${INST}\e[0m"
    echo -e "  WordPress 版本: \e[36m${WP_VER}\e[0m"
    echo -e "  当前镜像版本:   \e[32m$(env_get "$DIR/.env" IMAGE_TAG)\e[0m"
    echo -e "  仓库地址:       \e[36m$(env_get "$DIR/.env" REGISTRY_HOST)\e[0m"
    local _WG _PORT _MS_TYPE _MS_DOMAIN
    _WG=$(env_get "$DIR/.env" WG_IP)
    _PORT=$(env_get "$DIR/.env" WP_PORT); _PORT="${_PORT:-80}"
    _MS_TYPE=$(env_get "$DIR/.env" WP_MULTISITE_TYPE 2>/dev/null || true); _MS_TYPE="${_MS_TYPE:-single}"
    _MS_DOMAIN=$(env_get "$DIR/.env" WP_MULTISITE_DOMAIN 2>/dev/null || true)
    echo -e "  健康检查:       \e[36mhttp://${_WG}:${_PORT}/health\e[0m"
    if [[ "$_MS_TYPE" != "single" ]]; then
        echo -e "  Multisite:      \e[35m${_MS_TYPE}\e[0m${_MS_DOMAIN:+  根域名: \e[35m${_MS_DOMAIN}\e[0m}"
    fi
}

cmd_logs() {
    local DIR INST; _resolve_instance DIR INST
    [[ -f "$DIR/docker-compose.yml" ]] || error "未找到编排文件"
    echo "  1. 容器总日志  2. Nginx 访问日志  3. Nginx 错误日志"
    read -rp "选择 [默认: 1]: " LOG_CHOICE || true
    case "${LOG_CHOICE:-1}" in
        # [fix] v6.8: 去掉 -T 分配 TTY，Ctrl+C 仅中断容器内 tail 而非整个脚本
        2) dc "$DIR" exec wordpress tail -f /var/log/nginx/access.log ;;
        3) dc "$DIR" exec wordpress tail -f /var/log/nginx/error.log ;;
        *) dc "$DIR" logs -f --tail=100 wordpress ;;
    esac
}

cmd_stop()    { local DIR INST; _resolve_instance DIR INST; [[ -f "$DIR/docker-compose.yml" ]] || error "未找到编排文件"; dc "$DIR" stop    && log "已停止。"; }
cmd_start()   { local DIR INST; _resolve_instance DIR INST; [[ -f "$DIR/docker-compose.yml" ]] || error "未找到编排文件"; dc "$DIR" up -d   && log "已启动。"; }
cmd_restart() { local DIR INST; _resolve_instance DIR INST; [[ -f "$DIR/docker-compose.yml" ]] || error "未找到编排文件"; dc "$DIR" restart && log "已重启。"; }

cmd_destroy() {
    local DIR INST; _resolve_instance DIR INST
    [[ -f "$DIR/docker-compose.yml" ]] || error "未找到编排文件"
    warn "将停止容器并删除全部数据（不可恢复）。"
    read -rp "输入 'yes' 确认: " CONFIRM || true
    [[ "$CONFIRM" != "yes" ]] && { info "已取消"; return; }
    local WG_IP; WG_IP=$(env_get "$DIR/.env" "WG_IP")
    if [[ -n "$WG_IP" && -f "$NODES_FILE" ]]; then
        sed -i "/^${WG_IP}$/d" "$NODES_FILE"; log "已从节点列表移除 ${WG_IP}"
    fi
    dc "$DIR" down --volumes --remove-orphans 2>/dev/null || true
    rm -rf "$DIR"
    log "节点及数据已完全删除：${DIR}"
}

cmd_setup_r2() {
    local DIR INST; _resolve_instance DIR INST
    [[ -f "$DIR/.env" ]] || error "未找到 .env，请先完成节点初始化"

    # R2 凭证只在主节点生效：worker 不进 wp-admin，不需要也不应该持有凭证
    # [fix] v6.7: 原来写 "$(env_get ... || echo master)"，但 env_get 内部是
    # grep|cut|head -1，grep 未命中时 head 仍返回 0，"||" 分支永远不触发，
    # 缺 NODE_ROLE 的老实例会拿到空字符串而不是 "master"，导致真正的主节点
    # 也会被下面的判断误拒。改成先取值再用 ${VAR:-default} 兜底。
    local _ROLE; _ROLE=$(env_get "$DIR/.env" "NODE_ROLE" 2>/dev/null || true)
    _ROLE="${_ROLE:-master}"
    if [[ "$_ROLE" != "master" ]]; then
        error "R2 凭证只能在主节点配置（当前节点角色: ${_ROLE}）。Media Offloader 后台只有主节点能访问。"
    fi

    info "--- Advanced Media Offloader · Cloudflare R2 ---"
    local _CUR_KEY _CUR_BUCKET _CUR_DOMAIN _CUR_ENDPOINT
    _CUR_KEY=$(env_get "$DIR/.env" "R2_ACCESS_KEY" 2>/dev/null || true)
    _CUR_BUCKET=$(env_get "$DIR/.env" "R2_BUCKET" 2>/dev/null || true)
    _CUR_DOMAIN=$(env_get "$DIR/.env" "R2_DOMAIN" 2>/dev/null || true)
    _CUR_ENDPOINT=$(env_get "$DIR/.env" "R2_ENDPOINT" 2>/dev/null || true)
    [[ -n "$_CUR_KEY" ]] && info "  当前已配置（留空回车保留原值）"

    local R2_KEY R2_SECRET R2_BUCKET R2_DOMAIN R2_ENDPOINT
    read -rp "R2 Access Key Id [${_CUR_KEY:+已设置}]: " R2_KEY || true
    R2_KEY="${R2_KEY:-$_CUR_KEY}"
    [[ -n "$R2_KEY" ]] || error "Access Key 不能为空"
    read_secret "R2 Secret Access Key（留空保留原值）: " R2_SECRET
    [[ -n "$R2_SECRET" ]] || R2_SECRET=$(env_get "$DIR/.env" "R2_SECRET_KEY" 2>/dev/null || true)
    [[ -n "$R2_SECRET" ]] || error "Secret Key 不能为空"
    read -rp "R2 Bucket 名称 [${_CUR_BUCKET}]: " R2_BUCKET || true
    R2_BUCKET="${R2_BUCKET:-$_CUR_BUCKET}"
    [[ -n "$R2_BUCKET" ]] || error "Bucket 不能为空"
    read -rp "自定义域名 / CDN Domain（完整 https:// URL）[${_CUR_DOMAIN}]: " R2_DOMAIN || true
    R2_DOMAIN="${R2_DOMAIN:-$_CUR_DOMAIN}"
    read -rp "R2 Endpoint（完整 https://<account_id>.r2.cloudflarestorage.com）[${_CUR_ENDPOINT}]: " R2_ENDPOINT || true
    R2_ENDPOINT="${R2_ENDPOINT:-$_CUR_ENDPOINT}"
    [[ -n "$R2_ENDPOINT" ]] || error "Endpoint 不能为空"

    env_set "$DIR/.env" "R2_ACCESS_KEY" "$R2_KEY"
    env_set "$DIR/.env" "R2_SECRET_KEY" "$R2_SECRET"
    env_set "$DIR/.env" "R2_BUCKET"     "$R2_BUCKET"
    env_set "$DIR/.env" "R2_DOMAIN"     "$R2_DOMAIN"
    env_set "$DIR/.env" "R2_ENDPOINT"   "$R2_ENDPOINT"
    chmod 600 "$DIR/.env"
    log "R2 凭证已写入 .env"

    # 就地重新生成 wp-config-extra.php：复用已有 salts/Multisite 设置，
    # 只刷新 R2 常量，不影响登录态、不需要重新生成 wp-config.php 主文件
    # [fix] v6.6: 之前这里没读/传 PAGE_CACHE_ENABLED，函数内 $18 缺省为 false，
    # 配置 R2 会把已经开启的页面缓存开关静默改回关闭，这里补上读取+透传。
    local AK SK LK NK AS SS LS NS MT MD PC
    AK=$(env_get "$DIR/.env" "WP_AUTH_KEY");        SK=$(env_get "$DIR/.env" "WP_SECURE_AUTH_KEY")
    LK=$(env_get "$DIR/.env" "WP_LOGGED_IN_KEY");   NK=$(env_get "$DIR/.env" "WP_NONCE_KEY")
    AS=$(env_get "$DIR/.env" "WP_AUTH_SALT");       SS=$(env_get "$DIR/.env" "WP_SECURE_AUTH_SALT")
    LS=$(env_get "$DIR/.env" "WP_LOGGED_IN_SALT");  NS=$(env_get "$DIR/.env" "WP_NONCE_SALT")
    MT=$(env_get "$DIR/.env" "WP_MULTISITE_TYPE" 2>/dev/null || true); MT="${MT:-single}"
    MD=$(env_get "$DIR/.env" "WP_MULTISITE_DOMAIN" 2>/dev/null || true)
    PC=$(env_get "$DIR/.env" "PAGE_CACHE_ENABLED" 2>/dev/null || true); [[ "$PC" == "true" ]] || PC="false"
    _write_wp_config_extra "$DIR/conf/wp-config-extra.php" "master" \
        "$AK" "$SK" "$LK" "$NK" "$AS" "$SS" "$LS" "$NS" "$MT" "$MD" \
        "$R2_KEY" "$R2_SECRET" "$R2_BUCKET" "$R2_DOMAIN" "$R2_ENDPOINT" "$PC"
    log "wp-config-extra.php 已刷新（R2 常量已写入，salts 与页面缓存开关保持不变）"

    if dc "$DIR" ps --services --filter status=running 2>/dev/null | grep -q "wordpress"; then
        info "wp-config-extra.php 通过 require_once 加载，重启容器（非 force-recreate）即可生效"
        read -rp "立即重启容器？[y/N]: " _R2_APPLY || true
        if [[ "${_R2_APPLY,,}" == "y" ]]; then
            dc "$DIR" restart wordpress \
                && log "容器已重启，请到 Media Offloader 后台选择 Cloudflare R2 并 Test Connection" \
                || warn "容器重启失败，请手动执行 docker compose restart wordpress"
        else
            info "记得稍后执行菜单重启容器，或手动 docker compose restart wordpress 使配置生效"
        fi
    else
        info "节点未运行，下次启动时会自动加载该配置"
    fi
}

cmd_setup_pagecache() {
    local DIR INST; _resolve_instance DIR INST
    [[ -f "$DIR/.env" ]] || error "未找到 .env，请先完成节点初始化"

    # [fix] v6.7: 同 cmd_setup_r2，env_get 的 "||" 回退不生效，改用 ${VAR:-default}
    local _ROLE; _ROLE=$(env_get "$DIR/.env" "NODE_ROLE" 2>/dev/null || true)
    _ROLE="${_ROLE:-master}"
    local _CUR; _CUR=$(env_get "$DIR/.env" "PAGE_CACHE_ENABLED" 2>/dev/null || true)
    [[ "$_CUR" == "true" ]] || _CUR="false"

    info "--- Redis 全页缓存 ---"
    info "  当前状态: $([[ "$_CUR" == "true" ]] && echo "开启" || echo "关闭")"
    read -rp "开启页面缓存？[y/N，直接回车保持不变]: " _PC || true
    local NEW="$_CUR"
    if [[ -n "$_PC" ]]; then
        [[ "${_PC,,}" == "y" ]] && NEW="true" || NEW="false"
    fi

    if [[ "$NEW" == "$_CUR" ]]; then
        info "开关未变化（当前: $([[ "$NEW" == "true" ]] && echo 开启 || echo 关闭)），未做修改"
        return
    fi

    env_set "$DIR/.env" "PAGE_CACHE_ENABLED" "$NEW"
    chmod 600 "$DIR/.env"
    log "PAGE_CACHE_ENABLED=${NEW} 已写入 .env"

    # 回填 drop-in 文件：老实例（本功能上线前部署的节点）conf/ 下可能还没有这两个文件
    if [[ ! -s "$DIR/conf/advanced-cache.php" || ! -s "$DIR/conf/pagecache-purge.php" ]]; then
        info "回填页面缓存 drop-in 文件..."
        _write_advanced_cache_php        "$DIR/conf/advanced-cache.php"
        _write_pagecache_purge_mu_plugin "$DIR/conf/pagecache-purge.php"
    fi

    # 重写 compose：老实例的 docker-compose.yml 里可能还没有这两个 bind mount
    if [[ "$_ROLE" == "worker" ]]; then
        _write_worker_compose "$DIR" "$INST" "ro"
    else
        _write_init_compose "$DIR" "$INST"
    fi

    # 就地重新生成 wp-config-extra.php：复用已有 salts/Multisite/R2 设置，只刷新开关常量
    local AK SK LK NK AS SS LS NS MT MD R2K R2S R2B R2D R2E
    AK=$(env_get "$DIR/.env" "WP_AUTH_KEY");        SK=$(env_get "$DIR/.env" "WP_SECURE_AUTH_KEY")
    LK=$(env_get "$DIR/.env" "WP_LOGGED_IN_KEY");   NK=$(env_get "$DIR/.env" "WP_NONCE_KEY")
    AS=$(env_get "$DIR/.env" "WP_AUTH_SALT");       SS=$(env_get "$DIR/.env" "WP_SECURE_AUTH_SALT")
    LS=$(env_get "$DIR/.env" "WP_LOGGED_IN_SALT");  NS=$(env_get "$DIR/.env" "WP_NONCE_SALT")
    MT=$(env_get "$DIR/.env" "WP_MULTISITE_TYPE" 2>/dev/null || true); MT="${MT:-single}"
    MD=$(env_get "$DIR/.env" "WP_MULTISITE_DOMAIN" 2>/dev/null || true)
    if [[ "$_ROLE" == "master" ]]; then
        R2K=$(env_get "$DIR/.env" "R2_ACCESS_KEY" 2>/dev/null || true)
        R2S=$(env_get "$DIR/.env" "R2_SECRET_KEY" 2>/dev/null || true)
        R2B=$(env_get "$DIR/.env" "R2_BUCKET" 2>/dev/null || true)
        R2D=$(env_get "$DIR/.env" "R2_DOMAIN" 2>/dev/null || true)
        R2E=$(env_get "$DIR/.env" "R2_ENDPOINT" 2>/dev/null || true)
    fi
    _write_wp_config_extra "$DIR/conf/wp-config-extra.php" "$_ROLE" \
        "$AK" "$SK" "$LK" "$NK" "$AS" "$SS" "$LS" "$NS" "$MT" "$MD" \
        "$R2K" "$R2S" "$R2B" "$R2D" "$R2E" "$NEW"
    log "wp-config-extra.php 已刷新"

    if dc "$DIR" ps --services --filter status=running 2>/dev/null | grep -q "wordpress"; then
        info "新增了 bind mount，需要 up -d 让 compose 重新创建容器（普通 restart 不会挂载新文件）"
        read -rp "立即应用？[y/N]: " _APPLY || true
        if [[ "${_APPLY,,}" == "y" ]]; then
            dc "$DIR" up -d \
                && log "容器已重建，页面缓存开关已生效" \
                || warn "容器重建失败，请手动执行 docker compose up -d"
            [[ "$NEW" == "true" ]] && _flush_all_caches "$DIR"
        else
            info "记得稍后执行 docker compose up -d 使配置生效"
        fi
    else
        info "节点未运行，下次启动时会自动加载该配置"
    fi
}

cmd_retry_plugins() {
    local DIR INST; _resolve_instance DIR INST
    [[ -f "$DIR/docker-compose.yml" ]] || error "未找到编排文件"
    dc "$DIR" ps --services --filter status=running | grep -q "wordpress" \
        || { warn "wordpress 容器未运行，请先启动。"; return; }
    local _LOCALE _URL
    _LOCALE=$(env_get "$DIR/.env" "WP_LOCALE" 2>/dev/null || echo "zh_CN")
    # [fix] Multisite 模式下 _setup_plugins 需要 URL 来构造 --url flag；
    # 不传 URL 时 _WP_URL_FLAG 为空，所有 WP-CLI 命令报 "Site not found"。
    # 从 .env 读取 WP_SITEURL_FALLBACK（master_init 时写入的站点 URL）作为 URL。
    _URL=$(env_get "$DIR/.env" "WP_SITEURL_FALLBACK" 2>/dev/null || true)
    _setup_plugins "$DIR" "false" "${_URL}" "" "" "" "" "${_LOCALE:-zh_CN}" \
        || warn "插件配置未完全成功。"
}

cmd_flush() {
    local DIR INST; _resolve_instance DIR INST
    [[ -f "$DIR/docker-compose.yml" ]] || error "未找到编排文件"
    _flush_all_caches "$DIR"
}

cmd_nodes() {
    header "节点列表管理"
    # v6.0: 必须先选实例以确定 NODES_FILE
    local DIR INST; _resolve_instance DIR INST
    info "实例: ${INST}  节点文件: ${NODES_FILE}"
    echo "  1. 列出所有节点  2. 添加节点  3. 删除节点"
    read -rp "选择: " NODE_CHOICE || true
    case "$NODE_CHOICE" in
        1) [[ -s "$NODES_FILE" ]] && nl -ba "$NODES_FILE" || warn "节点列表为空：${NODES_FILE}" ;;
        2) read -rp "节点 WireGuard IP: " NEW_IP || true
           [[ -n "$NEW_IP" ]] || error "IP 不能为空"
           [[ "$NEW_IP" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || error "无效 IP 格式：${NEW_IP}"
           _register_node "$NEW_IP" ;;
        3) [[ -f "$NODES_FILE" ]] || { warn "节点列表不存在。"; return; }
           nl -ba "$NODES_FILE"; read -rp "输入要删除的行号: " LINE_NUM || true
           [[ "$LINE_NUM" =~ ^[0-9]+$ ]] || error "无效行号"
           sed -i "${LINE_NUM}d" "$NODES_FILE"; log "已删除第 ${LINE_NUM} 行。" ;;
        *) warn "无效输入" ;;
    esac
}

# ════════════════════════════════════════════════════════
# 备份（.env + conf/）→ rsync / S3 / AList
# ════════════════════════════════════════════════════════
cmd_backup() {
    header "备份实例配置"

    local DIR INST
    _resolve_instance DIR INST
    [[ -f "$DIR/.env" ]] || error "未找到 .env：${DIR}"
    local _ENV_INST; _ENV_INST=$(env_get "$DIR/.env" "WP_INSTANCE" 2>/dev/null || true)
    [[ -n "$_ENV_INST" ]] && INST="$_ENV_INST"
    info "实例: ${INST}"

    # 备份内容：.env + conf/ 目录（含 salts、nginx、php 配置等）
    local BACKUP_NAME="wp-backup-${INST}-$(date +%Y%m%d%H%M%S)"
    local BACKUP_TMP; BACKUP_TMP=$(mktemp -d /tmp/${BACKUP_NAME}-XXXXXX)

    local _BACKUP_DONE=false
    _backup_cleanup() {
        [[ "$_BACKUP_DONE" == "true" ]] && return
        _BACKUP_DONE=true
        rm -rf "$BACKUP_TMP"
    }
    # [fix] RETURN trap 在每次 shell 函数返回时都触发（包括 info/log 等辅助函数），
    # 会在 cp 执行前就把 BACKUP_TMP 删掉。改用 EXIT trap，
    # 函数末尾显式清理并重置，避免 trap 泄漏到后续菜单操作。
    trap '_backup_cleanup' EXIT

    info "打包备份文件..."
    cp "$DIR/.env" "$BACKUP_TMP/.env"
    cp -r "$DIR/conf" "$BACKUP_TMP/conf"
    # docker-compose.yml 可重新生成，但备一份无妨
    [[ -f "$DIR/docker-compose.yml" ]] && cp "$DIR/docker-compose.yml" "$BACKUP_TMP/docker-compose.yml"

    local BACKUP_TAR="/tmp/${BACKUP_NAME}.tar.gz"
    tar -czf "$BACKUP_TAR" -C "$(dirname "$BACKUP_TMP")" "$(basename "$BACKUP_TMP")"
    # [fix] v6.7: 包内 .env 含数据库/Redis密码、WP salts、R2 密钥，/tmp 默认
    # umask 下是明文可读，写完立即收紧权限，避免留在 /tmp 期间被同机其他用户读取。
    chmod 600 "$BACKUP_TAR"
    log "本地打包完成：${BACKUP_TAR}（$(du -sh "$BACKUP_TAR" | cut -f1)）"

    echo ""
    echo "  推送目标："
    echo "  1. rsync → 其他节点（WireGuard 内网）"
    echo "  2. S3 / 兼容对象存储（aws s3 cp）"
    echo "  3. AList 挂载目录（本地 cp）"
    echo "  4. rsync + S3"
    echo "  5. rsync + AList"
    echo "  6. S3 + AList"
    echo "  7. 全部推送"
    echo "  0. 仅保留本地，不推送"
    read -rp "选择 [默认: 0]: " _PUSH_CHOICE || true
    _PUSH_CHOICE="${_PUSH_CHOICE:-0}"

    # ── rsync ──
    _do_rsync() {
        if ! command -v rsync &>/dev/null; then
            warn "rsync 未安装，跳过"; return 1
        fi
        local RSYNC_HOST RSYNC_DEST RSYNC_USER
        read -rp "目标节点 WireGuard IP: " RSYNC_HOST || true
        [[ -n "$RSYNC_HOST" ]] || { warn "IP 不能为空，跳过 rsync"; return 1; }
        read -rp "目标目录 [默认: /srv/backups/]: " RSYNC_DEST || true
        RSYNC_DEST="${RSYNC_DEST:-/srv/backups/}"
        read -rp "SSH 用户 [默认: root]: " RSYNC_USER || true
        RSYNC_USER="${RSYNC_USER:-root}"

        info "rsync 推送到 ${RSYNC_USER}@${RSYNC_HOST}:${RSYNC_DEST} ..."
        rsync -avz --progress -e "ssh -o StrictHostKeyChecking=accept-new" \
            "$BACKUP_TAR" \
            "${RSYNC_USER}@${RSYNC_HOST}:${RSYNC_DEST}" \
        && log "rsync 推送完成" \
        || warn "rsync 推送失败，请检查 SSH 连通性"
    }

    # ── S3 ──
    _do_s3() {
        if ! command -v aws &>/dev/null; then
            warn "aws cli 未安装（pip install awscli 或 apt install awscli），跳过"; return 1
        fi
        local S3_BUCKET S3_ENDPOINT
        read -rp "S3 Bucket（如 s3://my-bucket/backups/）: " S3_BUCKET || true
        [[ -n "$S3_BUCKET" ]] || { warn "Bucket 不能为空，跳过 S3"; return 1; }
        S3_BUCKET="${S3_BUCKET%/}"
        read -rp "自定义 Endpoint（留空则用 AWS 官方）: " S3_ENDPOINT || true

        local _AWS_EXTRA=()
        [[ -n "$S3_ENDPOINT" ]] && _AWS_EXTRA+=(--endpoint-url "$S3_ENDPOINT")

        # 支持从 .env 读取 S3 凭证（可选）
        local _S3_KEY _S3_SECRET
        _S3_KEY=$(env_get    "$DIR/.env" "S3_ACCESS_KEY" 2>/dev/null || true)
        _S3_SECRET=$(env_get "$DIR/.env" "S3_SECRET_KEY" 2>/dev/null || true)
        if [[ -n "$_S3_KEY" && -n "$_S3_SECRET" ]]; then
            info "使用 .env 中的 S3 凭证"
            export AWS_ACCESS_KEY_ID="$_S3_KEY"
            export AWS_SECRET_ACCESS_KEY="$_S3_SECRET"
        fi

        info "S3 推送：${S3_BUCKET}/${BACKUP_NAME}.tar.gz ..."
        aws s3 cp "${_AWS_EXTRA[@]}" \
            "$BACKUP_TAR" \
            "${S3_BUCKET}/${BACKUP_NAME}.tar.gz" \
        && log "S3 推送完成：${S3_BUCKET}/${BACKUP_NAME}.tar.gz" \
        || warn "S3 推送失败，请检查凭证与 Bucket 权限"

        # 自动清理远端 30 天前的备份（同前缀）
        read -rp "自动清理 S3 上 30 天前的备份？[y/N]: " _S3_PRUNE || true
        if [[ "${_S3_PRUNE,,}" == "y" ]]; then
            local CUTOFF; CUTOFF=$(date -d '30 days ago' +%Y-%m-%dT%H:%M:%S 2>/dev/null \
                || date -v-30d +%Y-%m-%dT%H:%M:%S 2>/dev/null || true)
            if [[ -n "$CUTOFF" ]]; then
                info "清理 ${S3_BUCKET}/ 中早于 ${CUTOFF} 的备份..."
                aws s3 ls "${_AWS_EXTRA[@]}" "${S3_BUCKET}/" \
                    | awk -v cut="$CUTOFF" '$1 " " $2 < cut && /wp-backup-/ {print $4}' \
                    | while read -r _OBJ; do
                        aws s3 rm "${_AWS_EXTRA[@]}" "${S3_BUCKET}/${_OBJ}" && info "  已删除：${_OBJ}" || true
                    done
                log "S3 旧备份清理完成"
            else
                warn "无法计算 30 天前日期，跳过清理"
            fi
        fi
    }

    # ── AList 本地挂载目录 ──
    _do_alist() {
        local ALIST_DIR
        read -rp "AList 挂载目录 [默认: ${ALIST_DEFAULT_DIR}]: " ALIST_DIR || true
        ALIST_DIR="${ALIST_DIR:-${ALIST_DEFAULT_DIR}}"
        # 去掉末尾斜杠，统一处理
        ALIST_DIR="${ALIST_DIR%/}"

        # 检查挂载点是否可用（目录存在且非空挂载）
        if [[ ! -d "$ALIST_DIR" ]]; then
            mkdir -p "$ALIST_DIR" 2>/dev/null \
            || { warn "AList 目录创建失败：${ALIST_DIR}，请确认 AList 已挂载"; return 1; }
        fi

        # 简单检测：写入测试（FUSE 未挂载时 mkdir 会成功但写入失败）
        local _TEST_FILE="${ALIST_DIR}/.wp-deploy-write-test"
        if ! touch "$_TEST_FILE" 2>/dev/null; then
            warn "AList 目录不可写：${ALIST_DIR}，请确认 AList 已挂载且有写权限"
            return 1
        fi
        rm -f "$_TEST_FILE"

        info "复制到 AList：${ALIST_DIR}/${BACKUP_NAME}.tar.gz ..."
        if cp "$BACKUP_TAR" "${ALIST_DIR}/${BACKUP_NAME}.tar.gz"; then
            log "AList 推送完成：${ALIST_DIR}/${BACKUP_NAME}.tar.gz"
        else
            warn "AList 复制失败，请检查挂载状态"
            return 1
        fi

        # 自动清理 AList 目录内 30 天前的同实例备份
        # 用文件名中的时间戳（wp-backup-INST-YYYYmmddHHMMSS.tar.gz）判断，
        # 不依赖 FUSE mtime（网盘挂载后 mtime 可能被重置为当前时间）
        local _CUTOFF_TS _OLD_FILES _OLD_COUNT
        _CUTOFF_TS=$(date -d '30 days ago' +%Y%m%d%H%M%S 2>/dev/null \
            || date -v-30d +%Y%m%d%H%M%S 2>/dev/null || true)
        if [[ -n "$_CUTOFF_TS" ]]; then
            local -a _OLD_FILES=()
            while IFS= read -r _f; do
                local _fname; _fname=$(basename "$_f")
                # 提取 YYYYmmddHHMMSS 部分（文件名格式：wp-backup-INST-TIMESTAMP.tar.gz）
                local _ts; _ts=$(echo "$_fname" | grep -oP '\d{14}(?=\.tar\.gz$)' || true)
                [[ -n "$_ts" && "$_ts" < "$_CUTOFF_TS" ]] && _OLD_FILES+=("$_f")
            done < <(find "$ALIST_DIR" -maxdepth 1 -name "wp-backup-${INST}-*.tar.gz" 2>/dev/null)
            _OLD_COUNT="${#_OLD_FILES[@]}"
        else
            _OLD_COUNT=0
            warn "无法计算 30 天前时间戳，跳过 AList 旧备份清理"
        fi

        if [[ "$_OLD_COUNT" -gt 0 ]]; then
            read -rp "清理 AList 目录内 30 天前的旧备份（共 ${_OLD_COUNT} 个）？[y/N]: " _AL_PRUNE || true
            if [[ "${_AL_PRUNE,,}" == "y" ]]; then
                local _DEL_ERR=0
                for _del in "${_OLD_FILES[@]}"; do
                    rm -f "$_del" 2>/dev/null && info "  已删除：$(basename "$_del")" || { warn "  删除失败：$(basename "$_del")"; _DEL_ERR=1; }
                done
                [[ "$_DEL_ERR" -eq 0 ]] && log "AList 旧备份清理完成" \
                    || warn "部分旧备份清理失败，请手动检查"
            fi
        fi
    }

    case "$_PUSH_CHOICE" in
        1) _do_rsync ;;
        2) _do_s3 ;;
        3) _do_alist ;;
        4) _do_rsync; _do_s3 ;;
        5) _do_rsync; _do_alist ;;
        6) _do_s3; _do_alist ;;
        7) _do_rsync; _do_s3; _do_alist ;;
        0) info "仅保留本地备份：${BACKUP_TAR}" ;;
        *) warn "无效选择，仅保留本地备份" ;;
    esac

    _BACKUP_DONE=true
    rm -rf "$BACKUP_TMP"
    trap - EXIT

    echo ""
    log "备份完成！"
    echo -e "  本地文件: \e[32m${BACKUP_TAR}\e[0m"
    echo -e "  包含内容: .env  conf/（salts + nginx + php 配置）  docker-compose.yml"
    echo -e "  \e[33m提示：数据库与 uploads(S3) 有独立备份，无需在此处理。\e[0m"
}

# ════════════════════════════════════════════════════════
# 还原（从本地 tar.gz / rsync 拉取 / S3 下载 / AList 挂载目录）
# ════════════════════════════════════════════════════════
cmd_restore() {
    header "还原实例配置"

    local DIR INST
    _resolve_instance DIR INST
    local _ENV_INST; _ENV_INST=$(env_get "$DIR/.env" "WP_INSTANCE" 2>/dev/null || true)
    [[ -n "$_ENV_INST" ]] && INST="$_ENV_INST"
    info "实例: ${INST}  目录: ${DIR}"

    # ── 第一步：获取备份文件 ──
    echo ""
    echo "  备份来源："
    echo "  1. 本地文件（指定 tar.gz 路径）"
    echo "  2. rsync 从其他节点拉取"
    echo "  3. 从 S3 下载"
    echo "  4. AList 挂载目录（列表选择）"
    read -rp "选择 [默认: 1]: " _SRC_CHOICE || true
    _SRC_CHOICE="${_SRC_CHOICE:-1}"

    local RESTORE_TAR=""

    case "$_SRC_CHOICE" in
        1)
            read -rp "tar.gz 路径: " RESTORE_TAR || true
            [[ -f "$RESTORE_TAR" ]] || error "文件不存在：${RESTORE_TAR}"
            ;;
        2)
            if ! command -v rsync &>/dev/null; then error "rsync 未安装"; fi
            local RS_HOST RS_PATH RS_USER
            read -rp "来源节点 WireGuard IP: " RS_HOST || true
            [[ -n "$RS_HOST" ]] || error "IP 不能为空"
            read -rp "来源路径（如 /srv/backups/wp-backup-xxx.tar.gz）: " RS_PATH || true
            [[ -n "$RS_PATH" ]] || error "路径不能为空"
            read -rp "SSH 用户 [默认: root]: " RS_USER || true
            RS_USER="${RS_USER:-root}"
            RESTORE_TAR="/tmp/$(basename "$RS_PATH")"
            info "rsync 拉取中..."
            rsync -avz -e "ssh -o StrictHostKeyChecking=accept-new" \
                "${RS_USER}@${RS_HOST}:${RS_PATH}" "$RESTORE_TAR" \
            || error "rsync 拉取失败"
            log "已拉取到：${RESTORE_TAR}"
            ;;
        3)
            if ! command -v aws &>/dev/null; then error "aws cli 未安装"; fi
            local S3_BUCKET S3_ENDPOINT S3_OBJ
            read -rp "S3 Bucket（如 s3://my-bucket/backups）: " S3_BUCKET || true
            [[ -n "$S3_BUCKET" ]] || error "Bucket 不能为空"
            S3_BUCKET="${S3_BUCKET%/}"
            read -rp "自定义 Endpoint（留空则用 AWS 官方）: " S3_ENDPOINT || true
            local _AWS_EXTRA=()
            [[ -n "$S3_ENDPOINT" ]] && _AWS_EXTRA+=(--endpoint-url "$S3_ENDPOINT")

            # 支持从 .env 读凭证
            local _S3_KEY _S3_SECRET
            _S3_KEY=$(env_get    "$DIR/.env" "S3_ACCESS_KEY" 2>/dev/null || true)
            _S3_SECRET=$(env_get "$DIR/.env" "S3_SECRET_KEY" 2>/dev/null || true)
            if [[ -n "$_S3_KEY" && -n "$_S3_SECRET" ]]; then
                export AWS_ACCESS_KEY_ID="$_S3_KEY"
                export AWS_SECRET_ACCESS_KEY="$_S3_SECRET"
            fi

            echo ""
            info "列出 ${S3_BUCKET}/ 中的备份..."
            local -a S3_OBJS
            mapfile -t S3_OBJS < <(
                aws s3 ls "${_AWS_EXTRA[@]}" "${S3_BUCKET}/" 2>/dev/null \
                | awk '/wp-backup-/{print $4}' | sort -r
            )
            [[ ${#S3_OBJS[@]} -gt 0 ]] || error "未找到备份文件（前缀 wp-backup-）"
            local i=1
            for obj in "${S3_OBJS[@]}"; do echo "  ${i}. ${obj}"; i=$((i+1)); done
            read -rp "选择编号: " _S3_IDX || true
            [[ "$_S3_IDX" =~ ^[0-9]+$ ]] || error "无效编号"
            S3_OBJ="${S3_OBJS[$((_S3_IDX-1))]}"
            [[ -n "$S3_OBJ" ]] || error "无效选择"
            RESTORE_TAR="/tmp/${S3_OBJ}"
            info "下载 ${S3_BUCKET}/${S3_OBJ} ..."
            aws s3 cp "${_AWS_EXTRA[@]}" "${S3_BUCKET}/${S3_OBJ}" "$RESTORE_TAR" \
            || error "S3 下载失败"
            log "已下载到：${RESTORE_TAR}"
            ;;
        4)
            # ── AList 挂载目录 ──
            local ALIST_DIR
            read -rp "AList 挂载目录 [默认: ${ALIST_DEFAULT_DIR}]: " ALIST_DIR || true
            ALIST_DIR="${ALIST_DIR:-${ALIST_DEFAULT_DIR}}"
            ALIST_DIR="${ALIST_DIR%/}"
            [[ -d "$ALIST_DIR" ]] || error "AList 目录不存在：${ALIST_DIR}，请确认已挂载"

            local -a AL_FILES
            mapfile -t AL_FILES < <(
                find "$ALIST_DIR" -maxdepth 1 -name "wp-backup-*.tar.gz" \
                    2>/dev/null | sort -r
            )
            [[ ${#AL_FILES[@]} -gt 0 ]] || error "AList 目录中未找到备份文件（前缀 wp-backup-）"

            echo ""
            info "AList 目录中的备份（${ALIST_DIR}）："
            local i=1
            for f in "${AL_FILES[@]}"; do
                local _SIZE; _SIZE=$(du -sh "$f" 2>/dev/null | cut -f1 || echo "?")
                printf "  %2d. %-55s %s\n" "$i" "$(basename "$f")" "${_SIZE}"
                i=$((i+1))
            done
            read -rp "选择编号: " _AL_IDX || true
            [[ "$_AL_IDX" =~ ^[0-9]+$ ]] || error "无效编号"
            local _AL_SRC="${AL_FILES[$((_AL_IDX-1))]}"
            [[ -f "$_AL_SRC" ]] || error "无效选择"

            # 复制到 /tmp 再操作，避免 FUSE 读取中断影响后续解压
            RESTORE_TAR="/tmp/$(basename "$_AL_SRC")"
            info "从 AList 复制到本地临时目录..."
            cp "$_AL_SRC" "$RESTORE_TAR" \
            || error "AList 文件读取失败，请检查挂载状态"
            log "已复制到：${RESTORE_TAR}"
            ;;
        *)
            error "无效选择"
            ;;
    esac

    # [fix] v6.7: RESTORE_TAR（无论来自本地/rsync/S3/AList）落在 /tmp 后
    # 都含 .env 明文密钥，统一收紧权限
    chmod 600 "$RESTORE_TAR" 2>/dev/null || true

    # ── 第二步：预检 ──
    info "检查备份内容..."
    tar -tzf "$RESTORE_TAR" | grep -q '\.env' || error "备份包中未找到 .env，文件可能损坏"
    tar -tzf "$RESTORE_TAR" | grep -q 'conf/' || warn "备份包中未找到 conf/ 目录"

    echo ""
    warn "还原将覆盖以下文件（容器会自动重启）："
    echo "  ${DIR}/.env"
    echo "  ${DIR}/conf/"
    echo "  ${DIR}/docker-compose.yml（如包含）"
    read -rp "确认还原？[y/N]: " _CONFIRM || true
    [[ "${_CONFIRM,,}" == "y" ]] || { info "已取消"; return; }

    # ── 第三步：停止容器 ──
    if [[ -f "$DIR/docker-compose.yml" ]]; then
        info "停止容器..."
        dc "$DIR" stop 2>/dev/null || true
    fi

    # ── 第四步：备份当前配置（防止还原出问题） ──
    if [[ -f "$DIR/.env" ]]; then
        local _PRE_BAK="/tmp/wp-pre-restore-${INST}-$(date +%Y%m%d%H%M%S).tar.gz"
        tar -czf "$_PRE_BAK" -C "$DIR" .env conf docker-compose.yml 2>/dev/null || true
        chmod 600 "$_PRE_BAK" 2>/dev/null || true
        info "已将当前配置预备份至：${_PRE_BAK}"
    fi

    # ── 第五步：解压还原 ──
    info "解压还原..."
    local EXTRACT_TMP; EXTRACT_TMP=$(mktemp -d /tmp/wp-restore-XXXXXX)
    # [fix] v6.8: 防止路径遍历（ZipSlip），拒绝包含 .. 的路径
    if tar -tzf "$RESTORE_TAR" | grep -qE '\.\./|^/'; then
        error "备份包包含非法路径（路径遍历攻击？），已中止"
    fi
    tar -xzf "$RESTORE_TAR" -C "$EXTRACT_TMP" --anchored || error "解压失败"

    # 找到解压后的子目录（备份时用了随机 tmpdir 名）
    local RESTORE_SRC
    RESTORE_SRC=$(find "$EXTRACT_TMP" -maxdepth 1 -mindepth 1 -type d | head -1)
    [[ -n "$RESTORE_SRC" ]] || RESTORE_SRC="$EXTRACT_TMP"

    mkdir -p "$DIR/conf"
    [[ -f "$RESTORE_SRC/.env" ]]              && cp "$RESTORE_SRC/.env"              "$DIR/.env"              && log "  .env 已还原"
    [[ -d "$RESTORE_SRC/conf" ]]              && cp -r "$RESTORE_SRC/conf/." "$DIR/conf/"                     && log "  conf/ 已还原"
    [[ -f "$RESTORE_SRC/docker-compose.yml" ]] && cp "$RESTORE_SRC/docker-compose.yml" "$DIR/docker-compose.yml" && log "  docker-compose.yml 已还原"

    rm -rf "$EXTRACT_TMP"

    # ── 第六步：重建 compose（确保镜像名与实例一致） ──
    local _RESTORED_INST; _RESTORED_INST=$(env_get "$DIR/.env" "WP_INSTANCE" 2>/dev/null || true)
    _RESTORED_INST="${_RESTORED_INST:-$INST}"
    _write_worker_compose "$DIR" "$_RESTORED_INST"
    log "  docker-compose.yml 已按实例名重建"

    # ── 第七步：重启容器 ──
    local _REGISTRY_HOST; _REGISTRY_HOST=$(env_get "$DIR/.env" "REGISTRY_HOST")
    if [[ -n "$_REGISTRY_HOST" ]]; then
        local _IMAGE_TAG; _IMAGE_TAG=$(env_get "$DIR/.env" "IMAGE_TAG"); _IMAGE_TAG="${_IMAGE_TAG:-latest}"
        _ensure_insecure_registry "$_REGISTRY_HOST"
        # [fix] 原来只做 insecure-registry 配置，没有 docker login。
        # 全新节点或登录态过期时，docker compose up 拉取私有镜像会 401 失败。
        local _REG_USER _REG_PASS
        if [[ -f "$REGISTRY_DIR/.env" ]]; then
            _REG_USER=$(env_get "$REGISTRY_DIR/.env" "REGISTRY_USER")
            _REG_PASS=$(env_get "$REGISTRY_DIR/.env" "REGISTRY_PASS")
        else
            read -rp "仓库用户名: " _REG_USER || true
            read_secret "仓库密码: " _REG_PASS
        fi
        docker login "$_REGISTRY_HOST" -u "$_REG_USER" --password-stdin <<<"$_REG_PASS" \
        || { warn "仓库登录失败"; }
        # [fix] v6.8: 若登录失败且本地无对应镜像，直接报错中止，避免误导性"已重启"提示
        if ! docker images "${_REGISTRY_HOST}/wordpress-${_RESTORED_INST}:${_IMAGE_TAG}" --format '{{.ID}}' | grep -q . 2>/dev/null; then
            error "本地无镜像且仓库登录失败，还原中止。请检查仓库凭证后重试。"
        fi
        info "重启容器（镜像: ${_REGISTRY_HOST}/wordpress-${_RESTORED_INST}:${_IMAGE_TAG}）..."
        dc "$DIR" up -d --force-recreate 2>/dev/null \
        && log "容器已重启" \
        || warn "容器重启失败，请手动执行菜单 8（启动节点）"
        docker logout "$_REGISTRY_HOST" &>/dev/null || true
    else
        warn "未找到 REGISTRY_HOST，跳过自动重启，请手动执行菜单 8"
    fi

    echo ""
    log "还原完成！"
    echo -e "  \e[33m如 salts 已变更，所有节点登录 cookie 将失效，用户需重新登录（正常现象）。\e[0m"
}

cmd_self_update() {
    header "脚本自更新"

    local RAW_URL="${SCRIPT_GITHUB_RAW}"
    info "当前版本:  v${SCRIPT_VERSION}"
    info "更新来源:  ${RAW_URL}"
    info "安装路径:  ${SCRIPT_SELF}"
    echo ""

    # 允许用户临时覆盖 URL（私有 fork / 内网镜像）
    read -rp "按回车使用以上地址，或输入自定义 URL: " _CUSTOM_URL || true
    [[ -n "$_CUSTOM_URL" ]] && RAW_URL="$_CUSTOM_URL"

    # 下载到临时文件，校验后再替换
    local TMP_SCRIPT
    TMP_SCRIPT=$(mktemp /tmp/wp-deploy-update-XXXXXX.sh)

    local _UPDATE_CLEANUP_DONE=false
    _update_cleanup() {
        [[ "$_UPDATE_CLEANUP_DONE" == "true" ]] && return
        _UPDATE_CLEANUP_DONE=true
        rm -f "$TMP_SCRIPT"
    }
    trap '_update_cleanup' EXIT

    info "正在下载..."
    if ! curl -4 -fsSL --max-time 30 "$RAW_URL" -o "$TMP_SCRIPT"; then
        _update_cleanup; trap - EXIT
        error "下载失败，请检查网络或 URL：${RAW_URL}"
    fi

    # 基础完整性校验：必须是 bash 脚本且包含关键标识
    if ! head -1 "$TMP_SCRIPT" | grep -q "bash"; then
        _update_cleanup; trap - EXIT
        error "下载内容不是有效的 bash 脚本，已中止（可能是 404 页面或网络劫持）"
    fi
    if ! grep -q "wp-deploy" "$TMP_SCRIPT"; then
        _update_cleanup; trap - EXIT
        error "下载内容未通过关键词校验（未找到 wp-deploy 标识），已中止"
    fi

    # 语法检查
    if ! bash -n "$TMP_SCRIPT" 2>/dev/null; then
        _update_cleanup; trap - EXIT
        error "新版本语法检查失败，已中止更新"
    fi

    # 提取新版本号
    local NEW_VER
    NEW_VER=$(grep -oP 'SCRIPT_VERSION="\K[^"]+' "$TMP_SCRIPT" 2>/dev/null || echo "未知")
    info "新版本:    v${NEW_VER}"

    if [[ "$NEW_VER" == "$SCRIPT_VERSION" ]]; then
        warn "当前已是最新版本（v${SCRIPT_VERSION}），无需更新"
        _update_cleanup; trap - EXIT
        return
    fi

    echo ""
    read -rp "确认更新 v${SCRIPT_VERSION} → v${NEW_VER}？[y/N]: " _CONFIRM || true
    if [[ "${_CONFIRM,,}" != "y" ]]; then
        info "已取消"
        _update_cleanup; trap - EXIT
        return
    fi

    # 备份当前版本
    local BACKUP_PATH="${SCRIPT_SELF}.v${SCRIPT_VERSION}.bak"
    cp "$SCRIPT_SELF" "$BACKUP_PATH"
    log "已备份当前版本至: ${BACKUP_PATH}"

    # 原子替换：保留原始权限
    chmod --reference="$SCRIPT_SELF" "$TMP_SCRIPT"
    mv "$TMP_SCRIPT" "$SCRIPT_SELF" || error "脚本替换失败，请检查 ${SCRIPT_SELF} 所在目录的写入权限"
    _UPDATE_CLEANUP_DONE=true  # mv 已成功，不再需要 rm
    trap - EXIT

    log "更新完成！v${SCRIPT_VERSION} → v${NEW_VER}"
    echo -e "  \e[33m脚本已替换，请退出后重新运行以加载新版本。\e[0m"
    echo -e "  \e[36m旧版备份: ${BACKUP_PATH}\e[0m"
}

interactive_menu() {
    while true; do
        echo ""
        _c "1;35" "========================================"
        _c "1;35" "  WordPress 多节点分发管理 v${SCRIPT_VERSION}"
        _c "1;35" "  多实例 | Multisite | 单容器全打包"
        _c "1;35" "========================================"
        echo -e "  \e[36m── 仓库管理 ──────────────────────────\e[0m"
        echo -e "  \e[32m 1.\e[0m 部署私有镜像仓库"
        echo -e "  \e[36m── 主节点操作 ────────────────────────\e[0m"
        echo -e "  \e[32m 2.\e[0m 主节点初始化（建站 + 配置插件）"
        echo -e "  \e[32m 3.\e[0m 打包推送（核心+主题+插件 → 推送仓库）"
        echo -e "  \e[36m── 工作节点操作 ──────────────────────\e[0m"
        echo -e "  \e[32m 4.\e[0m 拉取部署 / 更新（首次 + 后续统一入口）"
        echo -e "  \e[33m 5.\e[0m 镜像回滚"
        echo -e "  \e[36m── 日常运维 ──────────────────────────\e[0m"
        echo -e "  \e[32m 6.\e[0m 查看状态（含 WP 版本 + 健康检查地址）"
        echo -e "  \e[32m 7.\e[0m 查看日志"
        echo -e "  \e[32m 8.\e[0m 启动节点"
        echo -e "  \e[32m 9.\e[0m 停止节点"
        echo -e "  \e[32m10.\e[0m 重启节点"
        echo -e "  \e[33m11.\e[0m 重试插件配置 / 补装语言包"
        echo -e "  \e[33m12.\e[0m 手动刷新全层缓存"
        echo -e "  \e[36m13.\e[0m 节点列表管理"
        echo -e "  \e[32m17.\e[0m 配置 R2 媒体卸载（Advanced Media Offloader）"
        echo -e "  \e[32m19.\e[0m 配置 Redis 全页缓存开关"
        echo -e "  \e[32m15.\e[0m 备份配置（.env + conf → rsync / S3 / AList）"
        echo -e "  \e[32m16.\e[0m 还原配置（本地 / rsync / S3 / AList）"
        echo -e "  \e[31m14.\e[0m 删除节点（不可恢复）"
        echo -e "  \e[36m18.\e[0m 脚本自更新（从 GitHub 拉取）"
        echo -e "  \e[36m 0.\e[0m 退出"
        echo "----------------------------------------"
        read -rp "选择: " CHOICE || true
        case "$CHOICE" in
            1)  cmd_registry ;;
            2)  cmd_master_init ;;
            3)  cmd_push ;;
            4)  cmd_pull_deploy ;;
            5)  cmd_rollback ;;
            6)  cmd_status ;;
            7)  cmd_logs ;;
            8)  cmd_start ;;
            9)  cmd_stop ;;
            10) cmd_restart ;;
            11) cmd_retry_plugins ;;
            12) cmd_flush ;;
            13) cmd_nodes ;;
            17) cmd_setup_r2 ;;
            18) cmd_self_update ;;
            19) cmd_setup_pagecache ;;
            14) cmd_destroy ;;
            15) cmd_backup ;;
            16) cmd_restore ;;
            0)  info "再见！"; exit 0 ;;
            *)  warn "无效输入" ;;
        esac
        read -rp "按回车继续..." || true
    done
}

check_deps
clear
interactive_menu
