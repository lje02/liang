#!/usr/bin/env bash
# ============================================================
# wp-deploy.sh — WordPress 多节点全自动部署
# v5.0
#   变更:
#     [fix] nginx-wp.conf 始终写占位符，主/工作节点统一 sed 替换
#     [fix] 语言包安装移至 _setup_plugins 末尾（菜单 11 也生效）
#     [fix] 主题/插件语言包一并安装
#     [new] Salts 本地生成、写入 .env，打包时注入 wp-config-extra.php
#           确保多节点 cookie 互认
#     [new] WP_DEBUG 显式关闭
#     [new] 禁用内置 WP-Cron，主节点初始化后打印 crontab 提示
#     [new] nginx 层 /health 健康检查端点
#     继承 v4.9 全部修复
# ============================================================
set -euo pipefail
export LANG=en_US.UTF-8
export LC_ALL=en_US.UTF-8

BASE_DIR="${BASE_DIR:-/srv}"
DEFAULT_DIR="${BASE_DIR}/wordpress"
WG_IFACE="${WG_IFACE:-wg0}"
NODES_FILE="${BASE_DIR}/nodes.conf"
REGISTRY_DIR="${BASE_DIR}/registry"

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
    if ss -tlnp | awk '{print $4}' | grep -qE ":${PORT}$"; then
        error "端口 ${IP}:${PORT} 已被占用，请先停止对应服务"
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
    IFS= read -rp "$PROMPT" VALUE || true
    VALUE="${VALUE#"${VALUE%%[![:space:]]*}"}"
    VALUE="${VALUE%"${VALUE##*[![:space:]]}"}"
    printf -v "$VAR_NAME" '%s' "$VALUE"
}

env_get() {
    local FILE="$1" KEY="$2"
    grep "^${KEY}=" "$FILE" 2>/dev/null | cut -d= -f2- | head -1
}

# 本地生成 64 字符随机字符串，不依赖外网
_gen_salt() {
    LC_ALL=C tr -dc 'A-Za-z0-9!@#$%^&*()-_=+[]{}|;:,.<>?' \
        < /dev/urandom 2>/dev/null | head -c 64; true
}

_register_node() {
    local IP="$1"
    if [[ ! "$IP" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
        error "_register_node: 无效 IP 格式：${IP}"
    fi
    touch "$NODES_FILE"
    if ! grep -qxF "$IP" "$NODES_FILE"; then
        [[ -s "$NODES_FILE" && "$(tail -c1 "$NODES_FILE")" != "" ]] && echo "" >> "$NODES_FILE"
        echo "$IP" >> "$NODES_FILE"
        log "节点 ${IP} 已注册到 ${NODES_FILE}"
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

# v5.0: 始终写占位符 __WG_IP__ / __WP_PORT__
# 调用方在宿主机用 sed 替换后再挂载或写入目标路径
# 新增 /health 端点供网关探活
_write_nginx_wp_conf() {
    local DEST="$1"
    cat > "$DEST" <<'CONF'
map $http_x_forwarded_proto $fastcgi_https {
    default "";
    https   "on";
}

server {
    listen __WG_IP__:__WP_PORT__ default_server;
    root /var/www/html;
    index index.php index.html;
    client_max_body_size 2048M;

    # 健康检查端点：纯 nginx 层响应，不经过 PHP-FPM
    location = /health {
        access_log off;
        return 200 "ok";
        add_header Content-Type text/plain;
    }

    location ~* \.(js|css|png|jpg|jpeg|gif|ico|svg|woff|woff2|webp|avif)$ {
        expires max;
        log_not_found off;
        add_header Cache-Control "public, immutable";
        try_files $uri =404;
    }

    location / {
        try_files $uri $uri/ /index.php?$args;
    }

    location ~ \.php$ {
        fastcgi_pass              127.0.0.1:9000;
        fastcgi_index             index.php;
        include                   fastcgi_params;
        fastcgi_param SCRIPT_FILENAME  $document_root$fastcgi_script_name;
        fastcgi_param HTTPS            $fastcgi_https if_not_empty;
        fastcgi_param HTTP_X_FORWARDED_PROTO $http_x_forwarded_proto;
        fastcgi_param HTTP_X_FORWARDED_FOR   $http_x_forwarded_for;
        fastcgi_param HTTP_X_REAL_IP         $http_x_real_ip;
        fastcgi_read_timeout      600;
        fastcgi_send_timeout      600;
        fastcgi_buffer_size       128k;
        fastcgi_buffers           4 256k;
    }

    location ~* /(?:wp-config\.php|\.env|\.git|\.htaccess|xmlrpc\.php) {
        deny all;
    }

    location ~* /wp-content/uploads/.*\.php$ {
        deny all;
    }
}
CONF
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

# v5.0:
#   - 接收 salts 参数，写入 define()，确保多节点 cookie 互认
#   - 显式关闭 WP_DEBUG
#   - 禁用内置 WP-Cron（DISABLE_WP_CRON），由宿主机 cron 定时触发
# 参数: $1=DEST $2=NODE_ROLE $3...$10=8个 salt 值（按 WP salt 顺序）
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
        printf "define('WP_DEBUG',                   false);\n\n"

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
    } > "$DEST"
}

_write_master_dockerfile() {
    local DIR="$1"
    cat > "$DIR/Dockerfile" <<'DOCKERFILE'
FROM php:8.4-fpm-alpine

RUN apk add --no-cache \
        nginx supervisor curl bash \
        libpng libpng-dev libjpeg-turbo libjpeg-turbo-dev \
        libwebp-dev freetype freetype-dev icu-dev libzip-dev zip unzip \
    && docker-php-ext-configure gd --with-freetype --with-jpeg --with-webp \
    && docker-php-ext-install -j$(nproc) gd mysqli zip intl exif opcache \
    && apk add --no-cache --virtual .build-deps $PHPIZE_DEPS \
    && pecl install redis \
    && docker-php-ext-enable redis \
    && apk del .build-deps libpng-dev libjpeg-turbo-dev freetype-dev \
    && rm -rf /tmp/pear /var/cache/apk/*

RUN curl -4 -fsSL https://raw.githubusercontent.com/wp-cli/builds/gh-pages/phar/wp-cli.phar \
        -o /usr/local/bin/wp \
    && chmod +x /usr/local/bin/wp

COPY wp-core/ /var/www/html/
RUN rm -f /var/www/html/wp-config.php /var/www/html/wp-config-sample.php

COPY wp-content/themes/   /var/www/html/wp-content/themes/
COPY wp-content/plugins/  /var/www/html/wp-content/plugins/

COPY conf/nginx.conf       /etc/nginx/nginx.conf
COPY conf/nginx-wp.conf    /etc/nginx/http.d/default.conf
COPY conf/php-uploads.ini  /usr/local/etc/php/conf.d/uploads.ini
COPY conf/opcache.ini      /usr/local/etc/php/conf.d/opcache.ini
COPY conf/php-fpm-www.conf /usr/local/etc/php-fpm.d/www.conf
COPY conf/supervisord.conf /etc/supervisord.conf
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
    && docker-php-ext-configure gd --with-freetype --with-jpeg --with-webp \
    && docker-php-ext-install -j$(nproc) gd mysqli zip intl exif opcache \
    && apk add --no-cache --virtual .build-deps $PHPIZE_DEPS \
    && pecl install redis \
    && docker-php-ext-enable redis \
    && apk del .build-deps libpng-dev libjpeg-turbo-dev freetype-dev \
    && rm -rf /tmp/pear /var/cache/apk/*

RUN curl -4 -fsSL https://raw.githubusercontent.com/wp-cli/builds/gh-pages/phar/wp-cli.phar \
        -o /usr/local/bin/wp \
    && chmod +x /usr/local/bin/wp

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
}

_write_init_compose() {
    local DIR="$1"
    cat > "$DIR/docker-compose.yml" <<'YAML'
services:
  wordpress:
    build:
      context: .
      dockerfile: Dockerfile
    image: wordpress-site-init:latest
    restart: unless-stopped
    network_mode: host
    environment:
      WG_IP:                  ${WG_IP}
      WP_PORT:                ${WP_PORT:-80}
      WORDPRESS_DB_HOST:      ${DB_HOST}:3306
      WORDPRESS_DB_NAME:      ${WORDPRESS_DB_NAME}
      WORDPRESS_DB_USER:      ${WORDPRESS_DB_USER}
      WORDPRESS_DB_PASSWORD:  ${WORDPRESS_DB_PASSWORD}
      REDIS_HOST:             ${REDIS_HOST}
      REDIS_PW:               ${REDIS_PW}
      WP_SITEURL_FALLBACK:    ${WP_SITEURL_FALLBACK}
    volumes:
      - ./data/uploads:/var/www/html/wp-content/uploads
      - ./data/cache:/var/www/html/wp-content/cache
      - ./conf/nginx.conf:/etc/nginx/nginx.conf:ro
      - ./conf/nginx-wp.conf:/etc/nginx/http.d/default.conf:ro
      - ./conf/php-uploads.ini:/usr/local/etc/php/conf.d/uploads.ini:ro
      - ./conf/opcache.ini:/usr/local/etc/php/conf.d/opcache.ini:ro
      - ./conf/php-fpm-www.conf:/usr/local/etc/php-fpm.d/www.conf:ro
      - ./conf/supervisord.conf:/etc/supervisord.conf:ro
      - ./conf/wp-config-extra.php:/etc/wordpress/wp-config-extra.php:ro
      - ./logs:/var/log/nginx
YAML
}

_write_worker_compose() {
    local DIR="$1"
    cat > "$DIR/docker-compose.yml" <<'YAML'
services:
  wordpress:
    image: ${REGISTRY_HOST}/wordpress-site:${IMAGE_TAG:-latest}
    restart: unless-stopped
    network_mode: host
    environment:
      WG_IP:                  ${WG_IP}
      WP_PORT:                ${WP_PORT:-80}
      WORDPRESS_DB_HOST:      ${DB_HOST}:3306
      WORDPRESS_DB_NAME:      ${WORDPRESS_DB_NAME}
      WORDPRESS_DB_USER:      ${WORDPRESS_DB_USER}
      WORDPRESS_DB_PASSWORD:  ${WORDPRESS_DB_PASSWORD}
      REDIS_HOST:             ${REDIS_HOST}
      REDIS_PW:               ${REDIS_PW}
      WP_SITEURL_FALLBACK:    ${WP_SITEURL_FALLBACK}
    volumes:
      - ./data/uploads:/var/www/html/wp-content/uploads
      - ./data/cache:/var/www/html/wp-content/cache
      - ./conf/nginx-wp.conf:/etc/nginx/http.d/default.conf:ro
      - ./conf/wp-config.php:/var/www/html/wp-config.php:ro
      - ./conf/wp-config-extra.php:/etc/wordpress/wp-config-extra.php:ro
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
# _setup_plugins
# ════════════════════════════════════════════════════════
_setup_plugins() {
    local DIR="$1"
    local IS_AUTO_INSTALL="${2:-false}"
    local URL="${3:-}" TITLE="${4:-}" ADMIN="${5:-}"
    local PASS="${6:-}" EMAIL="${7:-}" LOCALE="${8:-zh_CN}"

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

    if ! dc "$DIR" exec -T wordpress test -f /var/www/html/wp-config.php; then
        info "创建 wp-config.php ..."
        local DB_NAME DB_USER DB_PW DB_HOST
        DB_NAME=$(env_get "$DIR/.env" "WORDPRESS_DB_NAME")
        DB_USER=$(env_get "$DIR/.env" "WORDPRESS_DB_USER")
        DB_PW=$(env_get "$DIR/.env" "WORDPRESS_DB_PASSWORD")
        DB_HOST=$(env_get "$DIR/.env" "DB_HOST")

        "${WP_CMD[@]}" config create \
            --dbname="$DB_NAME" --dbuser="$DB_USER" --dbpass="$DB_PW" \
            --dbhost="$DB_HOST" --dbcharset=utf8mb4 --skip-check \
            || { warn "wp-config.php 创建失败，请检查数据库连接。"; return 1; }
        dc "$DIR" exec -T wordpress sed -i '/_KEY/d; /_SALT/d' /var/www/html/wp-config.php
        dc "$DIR" exec -T wordpress sh -c \
            "sed -i \"/require_once.*wp-settings/i require_once('\/etc\/wordpress\/wp-config-extra.php');\" /var/www/html/wp-config.php" || true
        log "wp-config.php 已自动生成。"
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
        else
            log "数据库已有数据，跳过安装。"
        fi
    fi

    # v5.0: 语言包安装移至此处，IS_AUTO_INSTALL 分支外
    # 菜单 11 重试时也会执行
    if [[ -n "$LOCALE" && "$LOCALE" != "en_US" ]]; then
        info "安装语言包: ${LOCALE}..."
        "${WP_CMD[@]}" language core install   "$LOCALE" 2>/dev/null || true
        "${WP_CMD[@]}" language theme  install --all "$LOCALE" 2>/dev/null || true
        "${WP_CMD[@]}" language plugin install --all "$LOCALE" 2>/dev/null || true
        "${WP_CMD[@]}" option update WPLANG "$LOCALE" || true
        if [[ -n "$ADMIN" ]]; then
            local ADMIN_ID
            ADMIN_ID=$("${WP_CMD[@]}" user get "$ADMIN" --field=ID 2>/dev/null || echo "1")
            "${WP_CMD[@]}" user meta update "$ADMIN_ID" locale "$LOCALE" 2>/dev/null || true
        fi
        log "界面语言已设为 ${LOCALE}"
    fi

    info "修复文件权限..."
    dc "$DIR" exec -T wordpress chown -R www-data:www-data /var/www/html/wp-content || true

    info "配置 Redis 插件..."
    if "${WP_CMD[@]}" plugin is-installed redis-cache &>/dev/null; then
        "${WP_CMD[@]}" plugin activate redis-cache || warn "Redis 插件激活失败"
    else
        "${WP_CMD[@]}" plugin install redis-cache --activate || warn "Redis 插件安装失败"
    fi

    info "探测 Redis 连通性..."
    local REDIS_HOST_VAL
    REDIS_HOST_VAL=$(env_get "$DIR/.env" "REDIS_HOST")
    local PROBE="\$c=@fsockopen('${REDIS_HOST_VAL}',6379,\$e,\$s,5);if(\$c){fclose(\$c);exit(0);}exit(1);"
    if dc "$DIR" exec -T wordpress php -r "$PROBE" 2>/dev/null; then
        "${WP_CMD[@]}" redis enable && log "Redis 对象缓存已启用！" || warn "redis enable 失败"
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
        info "已生成随机密码: ${REG_PASS}"
    fi

    mkdir -p "$REGISTRY_DIR"/{data,auth,certs}

    local HTPASSWD_TMP; HTPASSWD_TMP=$(mktemp)
    trap 'rm -f "$HTPASSWD_TMP"' RETURN ERR
    local HTPASSWD_OK=false
    if command -v htpasswd &>/dev/null; then
        htpasswd -Bbn "$REG_USER" "$REG_PASS" > "$HTPASSWD_TMP" && HTPASSWD_OK=true
    fi
    if [[ "$HTPASSWD_OK" != "true" ]]; then
        if docker run --rm --entrypoint htpasswd \
                httpd:alpine -Bbn "$REG_USER" "$REG_PASS" \
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

    local DAEMON_JSON="/etc/docker/daemon.json"
    local REGISTRY_ADDR="${WG_IP}:${REG_PORT}"
    if [[ -f "$DAEMON_JSON" ]]; then
        local _JQ_RC=0
        local _JQ_OUT
        _JQ_OUT=$(jq -e --arg addr "$REGISTRY_ADDR" \
            '.["insecure-registries"]? | index($addr)' "$DAEMON_JSON" 2>&1) || _JQ_RC=$?
        if [[ $_JQ_RC -eq 0 ]]; then
            :
        elif echo "$_JQ_OUT" | grep -qE "^null$|^false$"; then
            warn "请手动在 ${DAEMON_JSON} 中添加："
            warn "  \"insecure-registries\": [\"${REGISTRY_ADDR}\"]"
            warn "然后执行: systemctl restart docker"
        else
            warn "daemon.json 解析失败，请手动确认后添加 insecure-registries: ${REGISTRY_ADDR}"
            warn "解析错误: ${_JQ_OUT}"
        fi
    else
        printf '{\n  "insecure-registries": ["%s"]\n}\n' "${REGISTRY_ADDR}" > "$DAEMON_JSON"
        systemctl restart docker && log "Docker daemon 已更新并重启"
    fi

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
    read -rp "部署目录 [默认: ${DEFAULT_DIR}]: " DIR || true
    DIR="${DIR:-$DEFAULT_DIR}"

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
        info "已生成随机密码: ${WP_PASS}"
    fi
    read -rp "管理员邮箱 [默认: admin@example.com]: " WP_EMAIL || true
    WP_EMAIL="${WP_EMAIL:-admin@example.com}"

    info "--- 数据库 ---"
    read -rp "MariaDB WireGuard IP: " DB_HOST || true
    [[ -n "$DB_HOST" ]] || error "数据库 IP 不能为空"
    DB_HOST="${DB_HOST%%:*}"
    read -rp "数据库名 [默认: wordpress]: " DB_NAME || true; DB_NAME="${DB_NAME:-wordpress}"
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

    # v5.0: 生成统一 Salts，写入 .env 供后续 cmd_push 打包使用
    info "生成 WordPress Salts..."
    local S_AUTH_KEY S_SECURE_AUTH_KEY S_LOGGED_IN_KEY S_NONCE_KEY
    local S_AUTH_SALT S_SECURE_AUTH_SALT S_LOGGED_IN_SALT S_NONCE_SALT
    S_AUTH_KEY=$(_gen_salt)
    S_SECURE_AUTH_KEY=$(_gen_salt)
    S_LOGGED_IN_KEY=$(_gen_salt)
    S_NONCE_KEY=$(_gen_salt)
    S_AUTH_SALT=$(_gen_salt)
    S_SECURE_AUTH_SALT=$(_gen_salt)
    S_LOGGED_IN_SALT=$(_gen_salt)
    S_NONCE_SALT=$(_gen_salt)

    mkdir -p "$DIR"/{data/uploads,data/cache,conf,logs}

    {
        printf 'WORDPRESS_DB_PASSWORD=%s\n' "${DB_PW}"
        printf 'WORDPRESS_DB_NAME=%s\n'     "${DB_NAME}"
        printf 'WORDPRESS_DB_USER=%s\n'     "${DB_USER}"
        printf 'DB_HOST=%s\n'               "${DB_HOST}"
        printf 'REDIS_HOST=%s\n'            "${REDIS_HOST}"
        printf 'REDIS_PW=%s\n'              "${REDIS_PW}"
        printf 'WG_IP=%s\n'                 "${WG_IP}"
        printf 'WP_PORT=%s\n'               "${WP_PORT}"
        printf 'WP_SITEURL_FALLBACK=%s\n'   "${WP_URL}"
        printf 'REGISTRY_HOST=%s\n'         "${REGISTRY_HOST}"
        printf 'IMAGE_TAG=latest\n'
        printf 'NODE_ROLE=master\n'
        printf 'CF_ZONE_ID=%s\n'            "${CF_ZONE_ID}"
        printf 'CF_TOKEN=%s\n'              "${CF_TOKEN}"
        printf 'WP_AUTH_KEY=%s\n'           "${S_AUTH_KEY}"
        printf 'WP_SECURE_AUTH_KEY=%s\n'    "${S_SECURE_AUTH_KEY}"
        printf 'WP_LOGGED_IN_KEY=%s\n'      "${S_LOGGED_IN_KEY}"
        printf 'WP_NONCE_KEY=%s\n'          "${S_NONCE_KEY}"
        printf 'WP_AUTH_SALT=%s\n'          "${S_AUTH_SALT}"
        printf 'WP_SECURE_AUTH_SALT=%s\n'   "${S_SECURE_AUTH_SALT}"
        printf 'WP_LOGGED_IN_SALT=%s\n'     "${S_LOGGED_IN_SALT}"
        printf 'WP_NONCE_SALT=%s\n'         "${S_NONCE_SALT}"
    } > "$DIR/.env"
    chmod 600 "$DIR/.env"

    _write_nginx_main_conf    "$DIR/conf/nginx.conf"
    _write_nginx_wp_conf      "$DIR/conf/nginx-wp.conf"
    _sed_nginx_wp_conf        "$DIR/conf/nginx-wp.conf" "$WG_IP" "$WP_PORT"
    _write_php_uploads_ini    "$DIR/conf/php-uploads.ini"
    _write_opcache_ini        "$DIR/conf/opcache.ini"
    _write_php_fpm_www_conf   "$DIR/conf/php-fpm-www.conf"
    _write_supervisord_conf   "$DIR/conf/supervisord.conf"
    _write_wp_config_extra    "$DIR/conf/wp-config-extra.php" "master" \
        "$S_AUTH_KEY" "$S_SECURE_AUTH_KEY" "$S_LOGGED_IN_KEY" "$S_NONCE_KEY" \
        "$S_AUTH_SALT" "$S_SECURE_AUTH_SALT" "$S_LOGGED_IN_SALT" "$S_NONCE_SALT"
    _write_init_dockerfile    "$DIR"
    _write_entrypoint_script  "$DIR/entrypoint.sh"
    _write_init_compose       "$DIR"
    _register_node "$WG_IP"

    info "构建初始化镜像并启动..."
    docker compose -f "$DIR/docker-compose.yml" build --pull || error "镜像构建失败"
    docker compose -f "$DIR/docker-compose.yml" up -d       || error "容器启动失败"

    _setup_plugins "$DIR" "true" \
        "$WP_URL" "$WP_TITLE" "$WP_ADMIN" "$WP_PASS" "$WP_EMAIL" "$WP_LOCALE" \
        || warn "插件配置未完全成功，可通过菜单 11 重试"

    log "主节点初始化完成！"
    echo -e "  内网访问: \e[33mhttp://${WG_IP}\e[0m"
    echo -e "  站点:     \e[33m${WP_URL}\e[0m"
    echo -e "  账号:     \e[32m${WP_ADMIN}\e[0m / \e[32m${WP_PASS}\e[0m"
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
    read -rp "主节点目录 [默认: ${DEFAULT_DIR}]: " DIR || true
    DIR="${DIR:-$DEFAULT_DIR}"
    [[ -f "$DIR/.env" ]] || error "未找到 .env：${DIR}"

    local REGISTRY_HOST WG_IP
    REGISTRY_HOST=$(env_get "$DIR/.env" "REGISTRY_HOST")
    WG_IP=$(env_get "$DIR/.env" "WG_IP")
    [[ -n "$REGISTRY_HOST" ]] || error ".env 中缺少 REGISTRY_HOST"
    [[ -n "$WG_IP" ]]         || WG_IP=$(get_wg_ip)

    local IMAGE_TAG="v$(date +%Y%m%d%H%M)"
    local IMAGE_BASE="${REGISTRY_HOST}/wordpress-site"

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
    trap '_push_cleanup' RETURN ERR

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

    if [[ -z "$P_AUTH_KEY" ]]; then
        warn ".env 中未找到 Salts（旧版部署？），将生成新 Salts 并写回 .env"
        P_AUTH_KEY=$(_gen_salt);        P_SECURE_AUTH_KEY=$(_gen_salt)
        P_LOGGED_IN_KEY=$(_gen_salt);   P_NONCE_KEY=$(_gen_salt)
        P_AUTH_SALT=$(_gen_salt);       P_SECURE_AUTH_SALT=$(_gen_salt)
        P_LOGGED_IN_SALT=$(_gen_salt);  P_NONCE_SALT=$(_gen_salt)
        {
            printf 'WP_AUTH_KEY=%s\n'          "${P_AUTH_KEY}"
            printf 'WP_SECURE_AUTH_KEY=%s\n'   "${P_SECURE_AUTH_KEY}"
            printf 'WP_LOGGED_IN_KEY=%s\n'     "${P_LOGGED_IN_KEY}"
            printf 'WP_NONCE_KEY=%s\n'         "${P_NONCE_KEY}"
            printf 'WP_AUTH_SALT=%s\n'         "${P_AUTH_SALT}"
            printf 'WP_SECURE_AUTH_SALT=%s\n'  "${P_SECURE_AUTH_SALT}"
            printf 'WP_LOGGED_IN_SALT=%s\n'    "${P_LOGGED_IN_SALT}"
            printf 'WP_NONCE_SALT=%s\n'        "${P_NONCE_SALT}"
        } >> "$DIR/.env"
        # 同步更新主节点本地的 wp-config-extra.php
        _write_wp_config_extra "$DIR/conf/wp-config-extra.php" "master" \
            "$P_AUTH_KEY" "$P_SECURE_AUTH_KEY" "$P_LOGGED_IN_KEY" "$P_NONCE_KEY" \
            "$P_AUTH_SALT" "$P_SECURE_AUTH_SALT" "$P_LOGGED_IN_SALT" "$P_NONCE_SALT"
        warn "主节点容器需重启后 salts 才会生效：菜单 10 → 重启节点"
    fi

    mkdir -p "$BUILD_DIR/conf"
    _write_nginx_main_conf   "$BUILD_DIR/conf/nginx.conf"
    _write_nginx_wp_conf     "$BUILD_DIR/conf/nginx-wp.conf"
    # 镜像内保留占位符，工作节点 cmd_pull_deploy 拿到后 sed 替换再挂载
    _write_php_uploads_ini   "$BUILD_DIR/conf/php-uploads.ini"
    _write_opcache_ini       "$BUILD_DIR/conf/opcache.ini"
    _write_php_fpm_www_conf  "$BUILD_DIR/conf/php-fpm-www.conf"
    _write_supervisord_conf  "$BUILD_DIR/conf/supervisord.conf"
    # worker 角色 + 统一 salts
    _write_wp_config_extra   "$BUILD_DIR/conf/wp-config-extra.php" "worker" \
        "$P_AUTH_KEY" "$P_SECURE_AUTH_KEY" "$P_LOGGED_IN_KEY" "$P_NONCE_KEY" \
        "$P_AUTH_SALT" "$P_SECURE_AUTH_SALT" "$P_LOGGED_IN_SALT" "$P_NONCE_SALT"
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
    docker login "$REGISTRY_HOST" -u "$REG_USER" --password-stdin <<<"$REG_PASS" \
    || error "仓库登录失败"

    info "推送 ${IMAGE_BASE}:${IMAGE_TAG} ..."
    docker push "${IMAGE_BASE}:${IMAGE_TAG}" || error "推送失败"
    docker push "${IMAGE_BASE}:latest"       || error "推送 latest 失败"

    if grep -q '^IMAGE_TAG=' "$DIR/.env"; then
        sed -i "s|^IMAGE_TAG=.*|IMAGE_TAG=${IMAGE_TAG}|" "$DIR/.env"
    else
        echo "IMAGE_TAG=${IMAGE_TAG}" >> "$DIR/.env"
    fi

    info "清理本地旧镜像（保留最近 5 个）..."
    docker images "${IMAGE_BASE}" --format "{{.Tag}}\t{{.ID}}" \
        | grep -v 'latest' | sort -r | tail -n +6 \
        | awk '{print $2}' | xargs -r docker rmi 2>/dev/null || true

    log "推送完成！"
    echo -e "  镜像: \e[32m${IMAGE_BASE}:${IMAGE_TAG}\e[0m"
    echo -e "  WP 版本: \e[36m${WP_VER}\e[0m"
    echo -e "  \e[36m工作节点执行菜单 4（拉取部署/更新）即可。\e[0m"
}

# ════════════════════════════════════════════════════════
# 工作节点拉取部署 / 更新
# ════════════════════════════════════════════════════════
cmd_pull_deploy() {
    header "工作节点拉取部署 / 更新"
    read -rp "部署目录 [默认: ${DEFAULT_DIR}]: " DIR || true
    DIR="${DIR:-$DEFAULT_DIR}"

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
        read -rp "数据库名 [默认: wordpress]: " DB_NAME || true; DB_NAME="${DB_NAME:-wordpress}"
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

        {
            printf 'WORDPRESS_DB_PASSWORD=%s\n' "${DB_PW}"
            printf 'WORDPRESS_DB_NAME=%s\n'     "${DB_NAME}"
            printf 'WORDPRESS_DB_USER=%s\n'     "${DB_USER}"
            printf 'DB_HOST=%s\n'               "${DB_HOST}"
            printf 'REDIS_HOST=%s\n'            "${REDIS_HOST}"
            printf 'REDIS_PW=%s\n'              "${REDIS_PW}"
            printf 'WG_IP=%s\n'                 "${WG_IP}"
            printf 'WP_PORT=%s\n'               "${WP_PORT}"
            printf 'WP_SITEURL_FALLBACK=%s\n'   "${WP_URL}"
            printf 'REGISTRY_HOST=%s\n'         "${REGISTRY_HOST}"
            printf 'IMAGE_TAG=latest\n'
            printf 'NODE_ROLE=worker\n'
            printf 'CF_ZONE_ID=%s\n'            "${CF_ZONE_ID}"
            printf 'CF_TOKEN=%s\n'              "${CF_TOKEN}"
        } > "$DIR/.env"
        chmod 600 "$DIR/.env"
        # worker 的 wp-config-extra.php 来自镜像内（已打包 salts），此处生成占位版备用
        # 实际挂载的是从镜像导出后覆盖写入的版本（见下方 docker cp 流程）
        _write_worker_compose  "$DIR"
        _register_node "$WG_IP"
    fi

    REGISTRY_HOST=$(env_get "$DIR/.env" "REGISTRY_HOST")
    local IMAGE_TAG
    IMAGE_TAG=$(env_get "$DIR/.env" "IMAGE_TAG"); IMAGE_TAG="${IMAGE_TAG:-latest}"
    [[ -n "$REGISTRY_HOST" ]] || error ".env 中缺少 REGISTRY_HOST"

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
    docker login "$REGISTRY_HOST" -u "$REG_USER" --password-stdin <<<"$REG_PASS" \
    || error "仓库登录失败"

    local IMAGE_FULL="${REGISTRY_HOST}/wordpress-site:${IMAGE_TAG}"
    info "拉取镜像: ${IMAGE_FULL} ..."
    docker pull "$IMAGE_FULL" || error "镜像拉取失败"

    # v5.0: 从镜像导出 wp-config-extra.php（含 salts）到宿主机 conf/
    # 这是权威版本，不在宿主机重新生成，确保与打包时一致
    info "从镜像导出 wp-config-extra.php（含统一 Salts）..."
    local _TMP_CID
    _TMP_CID=$(docker create "${IMAGE_FULL}" sh 2>/dev/null || true)
    if [[ -n "$_TMP_CID" ]]; then
        docker cp "${_TMP_CID}:/etc/wordpress/wp-config-extra.php" \
            "$DIR/conf/wp-config-extra.php" 2>/dev/null \
        && log "  wp-config-extra.php 已导出" \
        || warn "  wp-config-extra.php 导出失败，将使用已有版本"
        docker rm -f "$_TMP_CID" &>/dev/null || true
    else
        warn "无法创建临时容器，跳过 wp-config-extra.php 导出"
    fi

    if [[ ! -f "$DIR/conf/wp-config.php" ]]; then
        info "预启动容器以生成 wp-config.php ..."
        if [[ ! -f "$DIR/docker-compose.yml" ]]; then
            _write_worker_compose "$DIR"
        fi
        dc "$DIR" up -d 2>/dev/null || true

        local RETRIES=20
        while ! dc "$DIR" exec -T wordpress sh -c 'command -v wp' &>/dev/null; do
            sleep 3; RETRIES=$((RETRIES - 1))
            [[ $RETRIES -le 0 ]] && { warn "容器未就绪，跳过 wp-config.php 生成"; break; }
        done

        if dc "$DIR" exec -T wordpress sh -c 'command -v wp' &>/dev/null; then
            local CID
            CID=$(docker compose -f "$DIR/docker-compose.yml" --env-file "$DIR/.env" ps -q wordpress)
            dc "$DIR" exec -T wordpress wp --allow-root config create \
                --dbname="$DB_NAME" --dbuser="$DB_USER" \
                --dbpass="$DB_PW"   --dbhost="$DB_HOST" \
                --dbcharset=utf8mb4 --path=/var/www/html \
                --skip-check 2>/dev/null \
            && dc "$DIR" exec -T wordpress sed -i '/_KEY/d; /_SALT/d' /var/www/html/wp-config.php \
            && dc "$DIR" exec -T wordpress sh -c \
                "sed -i \"/require_once.*wp-settings/i require_once('\/etc\/wordpress\/wp-config-extra.php');\" /var/www/html/wp-config.php" \
            && dc "$DIR" exec -T wordpress cp /var/www/html/wp-config.php /tmp/wp-config-out.php \
            && docker cp "${CID}:/tmp/wp-config-out.php" "$DIR/conf/wp-config.php" \
            && log "wp-config.php 已生成并导出至 conf/" \
            || warn "wp-config.php 生成失败，请手动创建或稍后重试（菜单 11）"
        fi
    fi

    # v5.0: 统一占位符替换逻辑（主/工作节点一致）
    local _WG_IP_VAL _WP_PORT_VAL
    _WG_IP_VAL=$(env_get "$DIR/.env" "WG_IP")
    _WP_PORT_VAL=$(env_get "$DIR/.env" "WP_PORT"); _WP_PORT_VAL="${_WP_PORT_VAL:-80}"

    if [[ ! -f "$DIR/conf/nginx-wp.conf" ]]; then
        info "从镜像导出 nginx-wp.conf ..."
        local _TMP_CID2
        _TMP_CID2=$(docker create "${IMAGE_FULL}" sh 2>/dev/null || true)
        if [[ -n "$_TMP_CID2" ]]; then
            docker cp "${_TMP_CID2}:/etc/nginx/http.d/default.conf" \
                "$DIR/conf/nginx-wp.conf" 2>/dev/null || true
            docker rm -f "$_TMP_CID2" &>/dev/null || true
        fi
    fi

    if [[ -f "$DIR/conf/nginx-wp.conf" ]]; then
        info "替换 nginx-wp.conf 占位符 → ${_WG_IP_VAL}:${_WP_PORT_VAL}"
        _sed_nginx_wp_conf "$DIR/conf/nginx-wp.conf" "$_WG_IP_VAL" "$_WP_PORT_VAL"
        if ! grep -q "nginx-wp.conf" "$DIR/docker-compose.yml" 2>/dev/null; then
            warn "docker-compose.yml 未挂载 nginx-wp.conf，请检查 _write_worker_compose 输出"
        fi
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
    read -rp "部署目录 [默认: ${DEFAULT_DIR}]: " DIR || true
    DIR="${DIR:-$DEFAULT_DIR}"
    [[ -f "$DIR/.env" ]] || error "未找到 .env：${DIR}"

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
        "http://${REGISTRY_HOST}/v2/wordpress-site/tags/list" 2>/dev/null)
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

    sed -i "s|^IMAGE_TAG=.*|IMAGE_TAG=${SELECTED_TAG}|" "$DIR/.env"
    docker login "$REGISTRY_HOST" -u "$REG_USER" --password-stdin <<<"$REG_PASS" &>/dev/null

    info "拉取 ${REGISTRY_HOST}/wordpress-site:${SELECTED_TAG} ..."
    docker pull "${REGISTRY_HOST}/wordpress-site:${SELECTED_TAG}" || error "拉取失败"
    dc "$DIR" up -d --force-recreate || error "容器重启失败"
    _flush_all_caches "$DIR"
    log "回滚到 ${SELECTED_TAG} 完成！"
}

# ════════════════════════════════════════════════════════
# 运维命令
# ════════════════════════════════════════════════════════
cmd_status() {
    read -rp "目录 [默认: ${DEFAULT_DIR}]: " DIR || true
    DIR="${DIR:-$DEFAULT_DIR}"
    [[ -f "$DIR/docker-compose.yml" ]] || error "未找到编排文件"
    dc "$DIR" ps; echo ""
    local WP_VER
    WP_VER=$(dc "$DIR" exec -T wordpress \
        cat /var/www/html/wp-includes/version.php 2>/dev/null \
        | grep -oP "(?<=wp_version = ')[^']+") || WP_VER="未知"
    echo -e "  WordPress 版本: \e[36m${WP_VER}\e[0m"
    echo -e "  当前镜像版本:   \e[32m$(env_get "$DIR/.env" IMAGE_TAG)\e[0m"
    echo -e "  仓库地址:       \e[36m$(env_get "$DIR/.env" REGISTRY_HOST)\e[0m"
    local _WG _PORT
    _WG=$(env_get "$DIR/.env" WG_IP)
    _PORT=$(env_get "$DIR/.env" WP_PORT); _PORT="${_PORT:-80}"
    echo -e "  健康检查:       \e[36mhttp://${_WG}:${_PORT}/health\e[0m"
}

cmd_logs() {
    read -rp "目录 [默认: ${DEFAULT_DIR}]: " DIR || true
    DIR="${DIR:-$DEFAULT_DIR}"
    [[ -f "$DIR/docker-compose.yml" ]] || error "未找到编排文件"
    echo "  1. 容器总日志  2. Nginx 访问日志  3. Nginx 错误日志"
    read -rp "选择 [默认: 1]: " LOG_CHOICE || true
    case "${LOG_CHOICE:-1}" in
        2) dc "$DIR" exec -T wordpress tail -f /var/log/nginx/access.log ;;
        3) dc "$DIR" exec -T wordpress tail -f /var/log/nginx/error.log ;;
        *) dc "$DIR" logs -f --tail=100 wordpress ;;
    esac
}

cmd_stop()    { read -rp "目录 [默认: ${DEFAULT_DIR}]: " DIR || true; DIR="${DIR:-$DEFAULT_DIR}"; [[ -f "$DIR/docker-compose.yml" ]] || error "未找到编排文件"; dc "$DIR" stop    && log "已停止。"; }
cmd_start()   { read -rp "目录 [默认: ${DEFAULT_DIR}]: " DIR || true; DIR="${DIR:-$DEFAULT_DIR}"; [[ -f "$DIR/docker-compose.yml" ]] || error "未找到编排文件"; dc "$DIR" up -d   && log "已启动。"; }
cmd_restart() { read -rp "目录 [默认: ${DEFAULT_DIR}]: " DIR || true; DIR="${DIR:-$DEFAULT_DIR}"; [[ -f "$DIR/docker-compose.yml" ]] || error "未找到编排文件"; dc "$DIR" restart && log "已重启。"; }

cmd_destroy() {
    read -rp "目录 [默认: ${DEFAULT_DIR}]: " DIR || true
    DIR="${DIR:-$DEFAULT_DIR}"
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

cmd_retry_plugins() {
    read -rp "目录 [默认: ${DEFAULT_DIR}]: " DIR || true
    DIR="${DIR:-$DEFAULT_DIR}"
    [[ -f "$DIR/docker-compose.yml" ]] || error "未找到编排文件"
    dc "$DIR" ps --services --filter status=running | grep -q "wordpress" \
        || { warn "wordpress 容器未运行，请先启动。"; return; }
    local _LOCALE
    _LOCALE=$(env_get "$DIR/.env" "WP_LOCALE" 2>/dev/null || echo "zh_CN")
    _setup_plugins "$DIR" "false" "" "" "" "" "" "${_LOCALE:-zh_CN}" \
        || warn "插件配置未完全成功。"
}

cmd_flush() {
    read -rp "目录 [默认: ${DEFAULT_DIR}]: " DIR || true
    DIR="${DIR:-$DEFAULT_DIR}"
    [[ -f "$DIR/docker-compose.yml" ]] || error "未找到编排文件"
    _flush_all_caches "$DIR"
}

cmd_nodes() {
    header "节点列表管理"
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

interactive_menu() {
    while true; do
        echo ""
        _c "1;35" "========================================"
        _c "1;35" "  WordPress 多节点分发管理 v5.0"
        _c "1;35" "  单容器全打包版（nginx+php+wordpress）"
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
        echo -e "  \e[31m14.\e[0m 删除节点（不可恢复）"
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
            14) cmd_destroy ;;
            0)  info "再见！"; exit 0 ;;
            *)  warn "无效输入" ;;
        esac
        read -rp "按回车继续..." || true
        clear
    done
}

check_deps
clear
interactive_menu