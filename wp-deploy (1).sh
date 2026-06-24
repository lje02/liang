#!/usr/bin/env bash
# ============================================================
# wp-deploy.sh — WordPress 多节点全自动部署
# v4.4  审计修复版
#   修复: 工作节点 wp-config.php docker run 挂载路径错误（CRITICAL）
#   修复: cmd_pull_deploy IS_FIRST=false 时变量未定义（HIGH）
#   修复: check_network /dev/tcp 命令注入（HIGH）
#   修复: EXIT trap 全局泄漏（MEDIUM）
#   修复: _setup_plugins WP 数组化（MEDIUM）
#   修复: htpasswd docker run 失败清空文件（MEDIUM）
#   修复: NGINX_CACHE_DIR 路径校验（MEDIUM）
#   改进: registry 监听 WG_IP 而非 0.0.0.0
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
    if ss -tlnp | grep -qF "${IP}:${PORT} "; then
        error "端口 ${IP}:${PORT} 已被占用，请先停止对应服务"
    fi
}

# ── 修复: 对 host/port 做严格格式校验，避免命令注入 ──
check_network() {
    local targets=("$@")
    for target in "${targets[@]}"; do
        IFS=: read -r host port <<< "$target"
        # 仅允许合法 IP/主机名和端口号
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
    IFS= read -rp "$PROMPT" VALUE
    VALUE="${VALUE#"${VALUE%%[![:space:]]*}"}"
    VALUE="${VALUE%"${VALUE##*[![:space:]]}"}"
    printf -v "$VAR_NAME" '%s' "$VALUE"
}

env_get() {
    local FILE="$1" KEY="$2"
    grep "^${KEY}=" "$FILE" 2>/dev/null | cut -d= -f2- | head -1
}

_register_node() {
    local IP="$1"
    touch "$NODES_FILE"
    if ! grep -qxF "$IP" "$NODES_FILE"; then
        [[ -s "$NODES_FILE" && "$(tail -c1 "$NODES_FILE")" != "" ]] && echo "" >> "$NODES_FILE"
        echo "$IP" >> "$NODES_FILE"
        log "节点 ${IP} 已注册到 ${NODES_FILE}"
    fi
}

# ════════════════════════════════════════════════════════
# 配置文件生成函数（与 v4.3 保持一致，无变化）
# ════════════════════════════════════════════════════════

_write_supervisord_conf()  { cat > "$1" <<'CONF'
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

_write_nginx_wp_conf() {
    local DEST="$1" WG_IP="$2"
    local TEMPLATE
    TEMPLATE=$(cat <<'TEMPLATE'
map $http_x_forwarded_proto $fastcgi_https {
    default "";
    https   "on";
}

server {
    listen __WG_IP__:80 default_server;
    root /var/www/html;
    index index.php index.html;
    client_max_body_size 2048M;

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
TEMPLATE
)
    printf "%s" "${TEMPLATE//__WG_IP__/${WG_IP:-__WG_IP__}}" > "$DEST"
}

_write_entrypoint_script() {
    local DEST="$1"
    cat > "$DEST" <<'ENTRYPOINT'
#!/bin/sh
set -e

if [ -n "${WG_IP}" ]; then
    FILE="/etc/nginx/http.d/default.conf"
    if grep -q '__WG_IP__' "$FILE" 2>/dev/null; then
        sed "s/__WG_IP__/${WG_IP}/g" "$FILE" > /tmp/default.conf.tmp
        cat /tmp/default.conf.tmp > "$FILE"
        rm -f /tmp/default.conf.tmp
        echo "Nginx listen IP set to ${WG_IP}"
    else
        echo "WG_IP already configured, skipping"
    fi
else
    echo "WARNING: WG_IP not set, using placeholder" >&2
fi

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

_write_s3_config_php() { cat > "$1" <<'PHP'
<?php
define('ILAB_MEDIA_S3_ACCESS_KEY',      getenv('AWS_ACCESS_KEY_ID'));
define('ILAB_MEDIA_S3_SECRET',          getenv('AWS_SECRET_ACCESS_KEY'));
define('ILAB_MEDIA_S3_BUCKET',          getenv('S3_BUCKET'));
define('ILAB_MEDIA_S3_REGION',          getenv('S3_REGION') ?: 'auto');
define('ILAB_MEDIA_S3_ENDPOINT',        getenv('S3_ENDPOINT') ?: '');
define('ILAB_MEDIA_S3_USE_PATH_STYLE',  false);
define('ILAB_MEDIA_S3_CDN_BASE',        getenv('S3_CDN_DOMAIN') ?: '');
define('ILAB_MEDIA_S3_DELETE_UPLOADS',  false);
define('ILAB_MEDIA_S3_UPLOAD_IMAGES',   true);
define('ILAB_MEDIA_S3_UPLOAD_VIDEOS',   true);
define('ILAB_MEDIA_S3_UPLOAD_AUDIO',    true);
define('ILAB_MEDIA_S3_UPLOAD_DOCS',     true);
PHP
}

_write_wp_config_extra() {
    local DEST="$1" NODE_ROLE="${2:-worker}"
    cat > "$DEST" <<'PHP_HEAD'
<?php
define('AUTOMATIC_UPDATER_DISABLED', true);
define('WP_AUTO_UPDATE_CORE',        false);
add_filter('auto_update_plugin', '__return_false');
add_filter('auto_update_theme',  '__return_false');
PHP_HEAD
    [[ "$NODE_ROLE" == "worker" ]] && printf "define('DISALLOW_FILE_MODS', true);\n" >> "$DEST"
    cat >> "$DEST" <<'PHP_BODY'

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
if (extension_loaded('redis') && php_sapi_name() !== 'cli') {
    ini_set('session.save_handler', 'redis');
    ini_set('session.save_path',
        'tcp://' . $_redis_host . ':6379?auth=' . urlencode($_redis_pw));
}

if (file_exists('/etc/wordpress/s3-config.php')) {
    require_once '/etc/wordpress/s3-config.php';
}
PHP_BODY
}

_write_master_dockerfile() {
    local DIR="$1"
    cat > "$DIR/Dockerfile" <<'DOCKERFILE'
FROM php:8.4-fpm-alpine

RUN apk add --no-cache \
        nginx supervisor curl bash less mariadb-client \
        libpng libpng-dev libjpeg-turbo libjpeg-turbo-dev \
        libwebp-dev freetype freetype-dev icu-dev libzip-dev zip unzip \
    && docker-php-ext-configure gd --with-freetype --with-jpeg --with-webp \
    && docker-php-ext-install -j$(nproc) gd mysqli pdo_mysql zip intl exif opcache bcmath \
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

COPY conf/nginx.conf      /etc/nginx/nginx.conf
COPY conf/nginx-wp.conf   /etc/nginx/http.d/default.conf
COPY conf/php-uploads.ini /usr/local/etc/php/conf.d/uploads.ini
COPY conf/opcache.ini     /usr/local/etc/php/conf.d/opcache.ini
COPY conf/php-fpm-www.conf /usr/local/etc/php-fpm.d/www.conf
COPY conf/supervisord.conf /etc/supervisord.conf
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

RUN mkdir -p /var/log/nginx /var/log/supervisor /run/nginx \
             /var/www/html/wp-content/uploads \
             /var/www/html/wp-content/cache /etc/wordpress \
    && chown -R www-data:www-data /var/www/html \
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
        nginx supervisor curl bash less mariadb-client \
        libpng libpng-dev libjpeg-turbo libjpeg-turbo-dev \
        libwebp-dev freetype freetype-dev icu-dev libzip-dev zip unzip \
    && docker-php-ext-configure gd --with-freetype --with-jpeg --with-webp \
    && docker-php-ext-install -j$(nproc) gd mysqli pdo_mysql zip intl exif opcache bcmath \
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
             /var/www/html/wp-content/uploads /etc/wordpress

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
      WORDPRESS_DB_HOST:      ${DB_HOST}:3306
      WORDPRESS_DB_NAME:      ${WORDPRESS_DB_NAME}
      WORDPRESS_DB_USER:      ${WORDPRESS_DB_USER}
      WORDPRESS_DB_PASSWORD:  ${WORDPRESS_DB_PASSWORD}
      AWS_ACCESS_KEY_ID:      ${AWS_ACCESS_KEY_ID}
      AWS_SECRET_ACCESS_KEY:  ${AWS_SECRET_ACCESS_KEY}
      S3_BUCKET:              ${S3_BUCKET}
      S3_REGION:              ${S3_REGION}
      S3_PROVIDER:            ${S3_PROVIDER}
      S3_ENDPOINT:            ${S3_ENDPOINT}
      S3_CDN_DOMAIN:          ${S3_CDN_DOMAIN}
      REDIS_HOST:             ${REDIS_HOST}
      REDIS_PW:               ${REDIS_PW}
      WP_SITEURL_FALLBACK:    ${WP_SITEURL_FALLBACK}
      WORDPRESS_CONFIG_EXTRA: "require_once('/etc/wordpress/wp-config-extra.php');"
    volumes:
      - ./data/uploads:/var/www/html/wp-content/uploads
      - ./data/cache:/var/www/html/wp-content/cache
      - ./conf/nginx.conf:/etc/nginx/nginx.conf:ro
      - ./conf/nginx-wp.conf:/etc/nginx/http.d/default.conf
      - ./conf/php-uploads.ini:/usr/local/etc/php/conf.d/uploads.ini:ro
      - ./conf/opcache.ini:/usr/local/etc/php/conf.d/opcache.ini:ro
      - ./conf/php-fpm-www.conf:/usr/local/etc/php-fpm.d/www.conf:ro
      - ./conf/supervisord.conf:/etc/supervisord.conf:ro
      - ./conf/s3-config.php:/etc/wordpress/s3-config.php:ro
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
      WORDPRESS_DB_HOST:      ${DB_HOST}:3306
      WORDPRESS_DB_NAME:      ${WORDPRESS_DB_NAME}
      WORDPRESS_DB_USER:      ${WORDPRESS_DB_USER}
      WORDPRESS_DB_PASSWORD:  ${WORDPRESS_DB_PASSWORD}
      AWS_ACCESS_KEY_ID:      ${AWS_ACCESS_KEY_ID}
      AWS_SECRET_ACCESS_KEY:  ${AWS_SECRET_ACCESS_KEY}
      S3_BUCKET:              ${S3_BUCKET}
      S3_REGION:              ${S3_REGION}
      S3_PROVIDER:            ${S3_PROVIDER}
      S3_ENDPOINT:            ${S3_ENDPOINT}
      S3_CDN_DOMAIN:          ${S3_CDN_DOMAIN}
      REDIS_HOST:             ${REDIS_HOST}
      REDIS_PW:               ${REDIS_PW}
      WP_SITEURL_FALLBACK:    ${WP_SITEURL_FALLBACK}
      WORDPRESS_CONFIG_EXTRA: "require_once('/etc/wordpress/wp-config-extra.php');"
    volumes:
      - ./data/uploads:/var/www/html/wp-content/uploads
      - ./conf/wp-config.php:/var/www/html/wp-config.php:ro
      - ./conf/s3-config.php:/etc/wordpress/s3-config.php:ro
      - ./conf/wp-config-extra.php:/etc/wordpress/wp-config-extra.php:ro
      - ./logs:/var/log/nginx
YAML
}

# ════════════════════════════════════════════════════════
# 缓存刷新（修复: NGINX_CACHE_DIR 路径校验）
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
    # ── 修复: 校验路径格式，防止注入 ──
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
# _setup_plugins（修复: WP 改为数组）
# ════════════════════════════════════════════════════════
_setup_plugins() {
    local DIR="$1"
    local IS_AUTO_INSTALL="${2:-false}"
    local URL="${3:-}" TITLE="${4:-}" ADMIN="${5:-}"
    local PASS="${6:-}" EMAIL="${7:-}" LOCALE="${8:-zh_CN}"

    info "等待 WordPress 容器就绪..."
    local RETRIES=30
    # ── 修复: WP 改为数组，防止 DIR 含空格时 word split ──
    local -a WP=(dc "$DIR" exec -T wordpress wp --allow-root)
    while ! "${WP[@]}" cli version &>/dev/null; do
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

        "${WP[@]}" config create \
            --dbname="$DB_NAME" --dbuser="$DB_USER" --dbpass="$DB_PW" \
            --dbhost="$DB_HOST" --dbcharset=utf8mb4 \
            --extra-php <<'PHP' || { warn "wp-config.php 创建失败，请检查数据库连接。"; return 1; }
define('WP_MEMORY_LIMIT', '512M');
define('WP_MAX_MEMORY_LIMIT', '1024M');
PHP
        dc "$DIR" exec -T wordpress sh -c \
            "echo \"require_once('/etc/wordpress/wp-config-extra.php');\" >> /var/www/html/wp-config.php" || true
        log "wp-config.php 已自动生成。"
    fi

    if [[ "$IS_AUTO_INSTALL" == "true" ]]; then
        if ! "${WP[@]}" core is-installed &>/dev/null; then
            info "安装 WordPress 核心..."
            "${WP[@]}" core install \
                --url="$URL" --title="$TITLE" \
                --admin_user="$ADMIN" --admin_password="$PASS" \
                --admin_email="$EMAIL" --locale="$LOCALE" --skip-email \
            || { warn "安装失败，请查看日志。"; return 1; }
            log "WordPress 安装成功！"
            echo -e "  站点: \e[32m${URL}\e[0m"
            echo -e "  账号: \e[32m${ADMIN}\e[0m / 密码: \e[32m${PASS}\e[0m"

            if [[ "$LOCALE" != "en_US" && -n "$LOCALE" ]]; then
                info "安装语言包: ${LOCALE}..."
                "${WP[@]}" language core install "$LOCALE" 2>/dev/null || true
                "${WP[@]}" option update WPLANG "$LOCALE" || true
                local ADMIN_ID
                ADMIN_ID=$("${WP[@]}" user get "$ADMIN" --field=ID 2>/dev/null || echo "1")
                "${WP[@]}" user meta update "$ADMIN_ID" locale "$LOCALE" 2>/dev/null || true
                log "界面语言已设为 ${LOCALE}"
            fi
        else
            log "数据库已有数据，跳过安装。"
        fi
    fi

    info "修复文件权限..."
    dc "$DIR" exec -T wordpress chown -R www-data:www-data /var/www/html/wp-content || true

    info "配置 Media Cloud 插件..."
    if "${WP[@]}" plugin is-installed amazon-s3-and-cloudfront &>/dev/null; then
        "${WP[@]}" plugin deactivate amazon-s3-and-cloudfront 2>/dev/null || true
        "${WP[@]}" plugin delete amazon-s3-and-cloudfront 2>/dev/null || true
    fi
    if "${WP[@]}" plugin is-installed ilab-media-tools &>/dev/null; then
        "${WP[@]}" plugin activate ilab-media-tools || warn "Media Cloud 激活失败"
    else
        "${WP[@]}" plugin install ilab-media-tools --activate || warn "Media Cloud 安装失败"
    fi

    info "配置 Redis 插件..."
    if "${WP[@]}" plugin is-installed redis-cache &>/dev/null; then
        "${WP[@]}" plugin activate redis-cache || warn "Redis 插件激活失败"
    else
        "${WP[@]}" plugin install redis-cache --activate || warn "Redis 插件安装失败"
    fi

    info "探测 Redis 连通性..."
    local REDIS_HOST_VAL
    REDIS_HOST_VAL=$(env_get "$DIR/.env" "REDIS_HOST")
    local PROBE="\$c=@fsockopen('${REDIS_HOST_VAL}',6379,\$e,\$s,5);if(\$c){fclose(\$c);exit(0);}exit(1);"
    if dc "$DIR" exec -T wordpress php -r "$PROBE" 2>/dev/null; then
        "${WP[@]}" redis enable && log "Redis 对象缓存已启用！" || warn "redis enable 失败"
    else
        warn "无法连接 Redis (${REDIS_HOST_VAL}:6379)，跳过启用"
    fi
}

# ════════════════════════════════════════════════════════
# 仓库部署（修复: htpasswd 失败保护 + 监听 WG_IP）
# ════════════════════════════════════════════════════════
cmd_registry() {
    header "部署私有镜像仓库"
    local WG_IP
    WG_IP=$(get_wg_ip)

    read -rp "仓库监听端口 [默认: 5000]: " REG_PORT
    REG_PORT="${REG_PORT:-5000}"
    [[ "$REG_PORT" =~ ^[0-9]+$ ]] || error "无效端口"
    check_port "$WG_IP" "$REG_PORT"

    read -rp "仓库认证用户名 [默认: wpregistry]: " REG_USER
    REG_USER="${REG_USER:-wpregistry}"
    local REG_PASS=""
    read_secret "仓库认证密码 [留空随机生成]: " REG_PASS
    if [[ -z "$REG_PASS" ]]; then
        REG_PASS=$(LC_ALL=C tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 20)
        info "已生成随机密码: ${REG_PASS}"
    fi

    mkdir -p "$REGISTRY_DIR"/{data,auth,certs}

    # ── 修复: htpasswd 写入临时文件，成功后再移入，防止失败清空 ──
    local HTPASSWD_TMP; HTPASSWD_TMP=$(mktemp)
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

    # ── 改进: 监听 WG_IP 而非 0.0.0.0，减少暴露面 ──
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

    local DAEMON_JSON="/etc/docker/daemon.json"
    local REGISTRY_ADDR="${WG_IP}:${REG_PORT}"
    if [[ -f "$DAEMON_JSON" ]]; then
        if ! jq -e --arg addr "$REGISTRY_ADDR" '.["insecure-registries"]? | index($addr)' "$DAEMON_JSON" &>/dev/null; then
            warn "请手动在 ${DAEMON_JSON} 中添加："
            warn "  \"insecure-registries\": [\"${REGISTRY_ADDR}\"]"
            warn "然后执行: systemctl restart docker"
        fi
    else
        cat > "$DAEMON_JSON" <<JSON
{
  "insecure-registries": ["${REGISTRY_ADDR}"]
}
JSON
        systemctl restart docker && log "Docker daemon 已更新并重启"
    fi

    log "私有仓库已部署！"
    echo -e "  仓库地址: \e[33m${REGISTRY_ADDR}\e[0m"
    echo -e "  用户名:   \e[32m${REG_USER}\e[0m"
    echo -e "  密码:     \e[32m${REG_PASS}\e[0m"
    echo -e "  \e[36m工作节点 .env 中填写 REGISTRY_HOST=${REGISTRY_ADDR}\e[0m"
}

# ════════════════════════════════════════════════════════
# 主节点初始化（与 v4.3 逻辑一致，无变化）
# ════════════════════════════════════════════════════════
cmd_master_init() {
    header "主节点初始化（全自动建站）"
    read -rp "部署目录 [默认: ${DEFAULT_DIR}]: " DIR
    DIR="${DIR:-$DEFAULT_DIR}"

    info "--- 站点配置 ---"
    read -rp "站点 URL（如 https://example.com）: " WP_URL
    [[ -z "$WP_URL" ]] && error "URL 不能为空"
    read -rp "站点名称 [默认: My WordPress]: " WP_TITLE
    WP_TITLE="${WP_TITLE:-My WordPress}"
    read -rp "安装语言 [默认: zh_CN]: " WP_LOCALE
    WP_LOCALE="${WP_LOCALE:-zh_CN}"
    read -rp "管理员用户名 [默认: wpadmin]: " WP_ADMIN
    WP_ADMIN="${WP_ADMIN:-wpadmin}"
    local WP_PASS=""
    read_secret "管理员密码 [留空随机生成]: " WP_PASS
    if [[ -z "$WP_PASS" ]]; then
        WP_PASS=$(LC_ALL=C tr -dc 'A-Za-z0-9!@#%^&*()' < /dev/urandom | head -c 16)
        info "已生成随机密码: ${WP_PASS}"
    fi
    read -rp "管理员邮箱 [默认: admin@example.com]: " WP_EMAIL
    WP_EMAIL="${WP_EMAIL:-admin@example.com}"

    info "--- 数据库 ---"
    read -rp "MariaDB WireGuard IP: " DB_HOST
    [[ -z "$DB_HOST" ]] && error "数据库 IP 不能为空"
    DB_HOST="${DB_HOST%%:*}"
    read -rp "数据库名 [默认: wordpress]: " DB_NAME; DB_NAME="${DB_NAME:-wordpress}"
    read -rp "数据库用户名 [默认: wpuser]: " DB_USER; DB_USER="${DB_USER:-wpuser}"
    local DB_PW=""
    read_secret "数据库密码: " DB_PW
    [[ -z "$DB_PW" ]] && error "数据库密码不能为空"

    info "--- Redis ---"
    read -rp "Redis WireGuard IP [默认同数据库 ${DB_HOST}]: " REDIS_HOST
    REDIS_HOST="${REDIS_HOST:-$DB_HOST}"; REDIS_HOST="${REDIS_HOST%%:*}"
    local REDIS_PW=""
    read_secret "Redis 密码: " REDIS_PW
    [[ -z "$REDIS_PW" ]] && error "Redis 密码不能为空"

    info "--- 对象存储 ---"
    echo "  1. AWS S3  2. Cloudflare R2  3. 其他 S3 兼容"
    read -rp "选择 [默认: 1]: " S3_CHOICE
    local S3_PROVIDER="aws" S3_ENDPOINT="" S3_REGION=""
    case "${S3_CHOICE:-1}" in
        2) S3_PROVIDER="cloudflare"
           read -rp "R2 Endpoint URL: " S3_ENDPOINT; [[ -z "$S3_ENDPOINT" ]] && error "必须填写 Endpoint"
           read -rp "区域 [默认: auto]: " S3_REGION; S3_REGION="${S3_REGION:-auto}" ;;
        3) S3_PROVIDER="other"
           read -rp "自定义 Endpoint URL: " S3_ENDPOINT; [[ -z "$S3_ENDPOINT" ]] && error "必须填写 Endpoint"
           read -rp "区域 [默认: us-east-1]: " S3_REGION; S3_REGION="${S3_REGION:-us-east-1}" ;;
        *) read -rp "区域 [默认: us-east-1]: " S3_REGION; S3_REGION="${S3_REGION:-us-east-1}" ;;
    esac
    read -rp "存储桶名称: " S3_BUCKET; [[ -z "$S3_BUCKET" ]] && error "桶名不能为空"
    local S3_KEY="" S3_SECRET=""
    read_secret "S3 Access Key ID: " S3_KEY; [[ -z "$S3_KEY" ]] && error "S3 Key 不能为空"
    read_secret "S3 Secret Access Key: " S3_SECRET; [[ -z "$S3_SECRET" ]] && error "S3 Secret 不能为空"
    read -rp "CDN 域名（留空跳过）: " S3_CDN_DOMAIN; S3_CDN_DOMAIN="${S3_CDN_DOMAIN:-}"

    info "--- 私有镜像仓库 ---"
    read -rp "Registry 地址（如 10.10.0.1:5000）: " REGISTRY_HOST
    [[ -z "$REGISTRY_HOST" ]] && error "Registry 地址不能为空"

    info "--- Cloudflare（可选）---"
    read -rp "CF Zone ID（留空跳过）: " CF_ZONE_ID; CF_ZONE_ID="${CF_ZONE_ID:-}"
    local CF_TOKEN=""
    [[ -n "$CF_ZONE_ID" ]] && read_secret "CF API Token: " CF_TOKEN

    local WG_IP
    WG_IP=$(get_wg_ip)
    log "WireGuard IP: ${WG_IP}"

    info "检查关键服务连通性..."
    check_network "${DB_HOST}:3306" "${REDIS_HOST}:6379" || true
    check_port "$WG_IP" "80"

    mkdir -p "$DIR"/{data/uploads,data/cache,conf,logs}

    cat > "$DIR/.env" <<EOF
WORDPRESS_DB_PASSWORD=${DB_PW}
WORDPRESS_DB_NAME=${DB_NAME}
WORDPRESS_DB_USER=${DB_USER}
DB_HOST=${DB_HOST}
REDIS_HOST=${REDIS_HOST}
REDIS_PW=${REDIS_PW}
AWS_ACCESS_KEY_ID=${S3_KEY}
AWS_SECRET_ACCESS_KEY=${S3_SECRET}
S3_BUCKET=${S3_BUCKET}
S3_REGION=${S3_REGION}
S3_PROVIDER=${S3_PROVIDER}
S3_ENDPOINT=${S3_ENDPOINT}
S3_CDN_DOMAIN=${S3_CDN_DOMAIN}
WG_IP=${WG_IP}
WP_SITEURL_FALLBACK=${WP_URL}
REGISTRY_HOST=${REGISTRY_HOST}
IMAGE_TAG=latest
NODE_ROLE=master
CF_ZONE_ID=${CF_ZONE_ID}
CF_TOKEN=${CF_TOKEN}
EOF
    chmod 600 "$DIR/.env"

    _write_nginx_main_conf    "$DIR/conf/nginx.conf"
    _write_nginx_wp_conf      "$DIR/conf/nginx-wp.conf" "$WG_IP"
    _write_php_uploads_ini    "$DIR/conf/php-uploads.ini"
    _write_opcache_ini        "$DIR/conf/opcache.ini"
    _write_php_fpm_www_conf   "$DIR/conf/php-fpm-www.conf"
    _write_supervisord_conf   "$DIR/conf/supervisord.conf"
    _write_s3_config_php      "$DIR/conf/s3-config.php"
    _write_wp_config_extra    "$DIR/conf/wp-config-extra.php" "master"
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
    echo -e "  \e[36m在后台完成主题/插件配置后，执行菜单 3（打包推送）分发到工作节点。\e[0m"
}

# ════════════════════════════════════════════════════════
# 主节点打包推送（修复: EXIT trap 函数返回后重置）
# ════════════════════════════════════════════════════════
cmd_push() {
    header "打包推送镜像到私有仓库"
    read -rp "主节点目录 [默认: ${DEFAULT_DIR}]: " DIR
    DIR="${DIR:-$DEFAULT_DIR}"
    [[ -f "$DIR/.env" ]] || error "未找到 .env：${DIR}"

    local REGISTRY_HOST WG_IP
    REGISTRY_HOST=$(env_get "$DIR/.env" "REGISTRY_HOST")
    WG_IP=$(env_get "$DIR/.env" "WG_IP")
    [[ -z "$REGISTRY_HOST" ]] && error ".env 中缺少 REGISTRY_HOST"
    [[ -z "$WG_IP" ]]         && WG_IP=$(get_wg_ip)

    local IMAGE_TAG="v$(date +%Y%m%d%H%M)"
    local IMAGE_BASE="${REGISTRY_HOST}/wordpress-site"

    local THEMES_COUNT PLUGINS_COUNT
    THEMES_COUNT=$(find "$DIR/data/wp-content/themes"  -maxdepth 1 -mindepth 1 -type d 2>/dev/null | wc -l)
    PLUGINS_COUNT=$(find "$DIR/data/wp-content/plugins" -maxdepth 1 -mindepth 1 -type d 2>/dev/null | wc -l)
    local WP_VER
    WP_VER=$(grep -oP "(?<=wp_version = ')[^']+" \
        "$DIR/data/wp-includes/version.php" 2>/dev/null) || WP_VER="未知"

    echo ""
    echo "  WordPress 版本: ${WP_VER}"
    echo "  主题数量:       ${THEMES_COUNT} 个"
    echo "  插件数量:       ${PLUGINS_COUNT} 个"
    echo "  镜像 tag:       ${IMAGE_TAG}"
    echo ""
    read -rp "确认打包推送？[y/N]: " CONFIRM
    [[ "${CONFIRM,,}" == "y" ]] || { info "已取消"; return; }

    local BUILD_DIR
    BUILD_DIR=$(mktemp -d /tmp/wp-build-XXXXXX)

    # ── 修复: trap 限定在本函数生命周期，返回前清理并重置 ──
    local _PUSH_CLEANUP_DONE=false
    _push_cleanup() {
        [[ "$_PUSH_CLEANUP_DONE" == "true" ]] && return
        _PUSH_CLEANUP_DONE=true
        rm -rf "$BUILD_DIR"
    }
    trap '_push_cleanup' RETURN ERR

    info "同步 WordPress 核心..."
    mkdir -p "$BUILD_DIR/wp-core"
    rsync -a --delete \
        --exclude='wp-content/' \
        --exclude='wp-config.php' \
        --exclude='wp-config-sample.php' \
        "$DIR/data/" "$BUILD_DIR/wp-core/"
    rm -f "$BUILD_DIR/wp-core/wp-config.php" \
          "$BUILD_DIR/wp-core/wp-config-sample.php"

    info "同步主题和插件..."
    mkdir -p "$BUILD_DIR/wp-content/themes" "$BUILD_DIR/wp-content/plugins"
    rsync -a --delete --exclude='uploads/' --exclude='cache/' \
        "$DIR/data/wp-content/themes/"  "$BUILD_DIR/wp-content/themes/"
    rsync -a --delete --exclude='uploads/' --exclude='cache/' \
        "$DIR/data/wp-content/plugins/" "$BUILD_DIR/wp-content/plugins/"

    info "生成配置文件..."
    mkdir -p "$BUILD_DIR/conf"
    _write_nginx_main_conf   "$BUILD_DIR/conf/nginx.conf"
    _write_nginx_wp_conf     "$BUILD_DIR/conf/nginx-wp.conf" ""
    _write_php_uploads_ini   "$BUILD_DIR/conf/php-uploads.ini"
    _write_opcache_ini       "$BUILD_DIR/conf/opcache.ini"
    _write_php_fpm_www_conf  "$BUILD_DIR/conf/php-fpm-www.conf"
    _write_supervisord_conf  "$BUILD_DIR/conf/supervisord.conf"
    _write_entrypoint_script "$BUILD_DIR/entrypoint.sh"
    _write_master_dockerfile "$BUILD_DIR"

    info "构建镜像: ${IMAGE_BASE}:${IMAGE_TAG} ..."
    docker build --pull --no-cache -t "${IMAGE_BASE}:${IMAGE_TAG}" -t "${IMAGE_BASE}:latest" "$BUILD_DIR" \
    || error "镜像构建失败"

    local REG_USER REG_PASS
    if [[ -f "$REGISTRY_DIR/.env" ]]; then
        REG_USER=$(env_get "$REGISTRY_DIR/.env" "REGISTRY_USER")
        REG_PASS=$(env_get "$REGISTRY_DIR/.env" "REGISTRY_PASS")
    else
        read -rp "仓库用户名: " REG_USER
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
# 修复: IS_FIRST=false 时从 .env 读取数据库变量
# 修复: wp-config.php 生成改用 exec 而非 docker run
# ════════════════════════════════════════════════════════
cmd_pull_deploy() {
    header "工作节点拉取部署 / 更新"
    read -rp "部署目录 [默认: ${DEFAULT_DIR}]: " DIR
    DIR="${DIR:-$DEFAULT_DIR}"

    local IS_FIRST=false
    # 声明变量，避免 set -u 在 IS_FIRST=false 时报错
    local DB_HOST="" DB_NAME="" DB_USER="" DB_PW="" REDIS_HOST="" REDIS_PW=""
    local S3_PROVIDER="" S3_ENDPOINT="" S3_REGION="" S3_BUCKET=""
    local S3_KEY="" S3_SECRET="" S3_CDN_DOMAIN="" WP_URL=""
    local REGISTRY_HOST="" CF_ZONE_ID="" CF_TOKEN="" WG_IP=""

    if [[ ! -f "$DIR/.env" ]]; then
        IS_FIRST=true
        info "未检测到 .env，进入首次部署配置..."

        info "--- 数据库 ---"
        read -rp "MariaDB WireGuard IP: " DB_HOST
        [[ -z "$DB_HOST" ]] && error "数据库 IP 不能为空"
        DB_HOST="${DB_HOST%%:*}"
        read -rp "数据库名 [默认: wordpress]: " DB_NAME; DB_NAME="${DB_NAME:-wordpress}"
        read -rp "数据库用户名 [默认: wpuser]: " DB_USER; DB_USER="${DB_USER:-wpuser}"
        read_secret "数据库密码: " DB_PW; [[ -z "$DB_PW" ]] && error "数据库密码不能为空"

        info "--- Redis ---"
        read -rp "Redis WireGuard IP [默认: ${DB_HOST}]: " REDIS_HOST
        REDIS_HOST="${REDIS_HOST:-$DB_HOST}"; REDIS_HOST="${REDIS_HOST%%:*}"
        read_secret "Redis 密码: " REDIS_PW; [[ -z "$REDIS_PW" ]] && error "Redis 密码不能为空"

        info "--- 对象存储 ---"
        echo "  1. AWS S3   2. Cloudflare R2   3. 其他 S3 兼容"
        read -rp "选择 [默认: 1]: " S3_CHOICE
        S3_PROVIDER="aws"; S3_ENDPOINT=""; S3_REGION=""
        case "${S3_CHOICE:-1}" in
            2) S3_PROVIDER="cloudflare"
               read -rp "R2 Endpoint URL: " S3_ENDPOINT; [[ -z "$S3_ENDPOINT" ]] && error "必须填写 Endpoint"
               read -rp "区域 [默认: auto]: " S3_REGION; S3_REGION="${S3_REGION:-auto}" ;;
            3) S3_PROVIDER="other"
               read -rp "自定义 Endpoint URL: " S3_ENDPOINT; [[ -z "$S3_ENDPOINT" ]] && error "必须填写 Endpoint"
               read -rp "区域 [默认: us-east-1]: " S3_REGION; S3_REGION="${S3_REGION:-us-east-1}" ;;
            *) read -rp "区域 [默认: us-east-1]: " S3_REGION; S3_REGION="${S3_REGION:-us-east-1}" ;;
        esac
        read -rp "存储桶名称: " S3_BUCKET; [[ -z "$S3_BUCKET" ]] && error "桶名不能为空"
        read_secret "S3 Access Key ID: " S3_KEY; [[ -z "$S3_KEY" ]] && error "S3 Key 不能为空"
        read_secret "S3 Secret Access Key: " S3_SECRET; [[ -z "$S3_SECRET" ]] && error "S3 Secret 不能为空"
        read -rp "CDN 域名（留空跳过）: " S3_CDN_DOMAIN; S3_CDN_DOMAIN="${S3_CDN_DOMAIN:-}"

        info "--- 站点 ---"
        read -rp "站点 URL（如 https://example.com）: " WP_URL
        [[ -z "$WP_URL" ]] && error "URL 不能为空"

        info "--- 私有镜像仓库 ---"
        read -rp "Registry 地址（如 10.10.0.1:5000）: " REGISTRY_HOST
        [[ -z "$REGISTRY_HOST" ]] && error "Registry 地址不能为空"

        info "--- Cloudflare（可选）---"
        read -rp "CF Zone ID（留空跳过）: " CF_ZONE_ID; CF_ZONE_ID="${CF_ZONE_ID:-}"
        [[ -n "$CF_ZONE_ID" ]] && read_secret "CF API Token: " CF_TOKEN

        WG_IP=$(get_wg_ip)
        check_port "$WG_IP" "80"
        check_network "${DB_HOST}:3306" "${REDIS_HOST}:6379" || true

        mkdir -p "$DIR"/{data/uploads,conf,logs}

        cat > "$DIR/.env" <<EOF
WORDPRESS_DB_PASSWORD=${DB_PW}
WORDPRESS_DB_NAME=${DB_NAME}
WORDPRESS_DB_USER=${DB_USER}
DB_HOST=${DB_HOST}
REDIS_HOST=${REDIS_HOST}
REDIS_PW=${REDIS_PW}
AWS_ACCESS_KEY_ID=${S3_KEY}
AWS_SECRET_ACCESS_KEY=${S3_SECRET}
S3_BUCKET=${S3_BUCKET}
S3_REGION=${S3_REGION}
S3_PROVIDER=${S3_PROVIDER}
S3_ENDPOINT=${S3_ENDPOINT}
S3_CDN_DOMAIN=${S3_CDN_DOMAIN}
WG_IP=${WG_IP}
WP_SITEURL_FALLBACK=${WP_URL}
REGISTRY_HOST=${REGISTRY_HOST}
IMAGE_TAG=latest
NODE_ROLE=worker
CF_ZONE_ID=${CF_ZONE_ID}
CF_TOKEN=${CF_TOKEN}
EOF
        chmod 600 "$DIR/.env"
        _write_s3_config_php   "$DIR/conf/s3-config.php"
        _write_wp_config_extra "$DIR/conf/wp-config-extra.php" "worker"
        _write_worker_compose  "$DIR"
        _register_node "$WG_IP"
    fi

    # ── 修复: IS_FIRST=false 时从 .env 读取所有需要的变量 ──
    REGISTRY_HOST=$(env_get "$DIR/.env" "REGISTRY_HOST")
    local IMAGE_TAG
    IMAGE_TAG=$(env_get "$DIR/.env" "IMAGE_TAG"); IMAGE_TAG="${IMAGE_TAG:-latest}"
    [[ -z "$REGISTRY_HOST" ]] && error ".env 中缺少 REGISTRY_HOST"

    # 供后续 wp-config 生成使用（IS_FIRST=false 时也要读）
    DB_HOST="${DB_HOST:-$(env_get "$DIR/.env" "DB_HOST")}"
    DB_NAME="${DB_NAME:-$(env_get "$DIR/.env" "WORDPRESS_DB_NAME")}"
    DB_USER="${DB_USER:-$(env_get "$DIR/.env" "WORDPRESS_DB_USER")}"
    DB_PW="${DB_PW:-$(env_get "$DIR/.env" "WORDPRESS_DB_PASSWORD")}"

    local REG_USER REG_PASS
    if [[ -f "$REGISTRY_DIR/.env" ]]; then
        REG_USER=$(env_get "$REGISTRY_DIR/.env" "REGISTRY_USER")
        REG_PASS=$(env_get "$REGISTRY_DIR/.env" "REGISTRY_PASS")
    else
        read -rp "仓库用户名: " REG_USER
        read_secret "仓库密码: " REG_PASS
    fi
    docker login "$REGISTRY_HOST" -u "$REG_USER" --password-stdin <<<"$REG_PASS" \
    || error "仓库登录失败"

    local IMAGE_FULL="${REGISTRY_HOST}/wordpress-site:${IMAGE_TAG}"
    info "拉取镜像: ${IMAGE_FULL} ..."
    docker pull "$IMAGE_FULL" || error "镜像拉取失败"

    # ── 修复: wp-config.php 先启动容器，再用 exec 生成，避免挂载路径错误 ──
    if [[ ! -f "$DIR/conf/wp-config.php" ]]; then
        info "预启动容器以生成 wp-config.php ..."
        # 先以 compose up 启动（若已有 compose 文件）
        if [[ -f "$DIR/docker-compose.yml" ]]; then
            dc "$DIR" up -d 2>/dev/null || true
        else
            _write_worker_compose "$DIR"
            dc "$DIR" up -d 2>/dev/null || true
        fi

        # 等待容器可用
        local RETRIES=20
        while ! dc "$DIR" exec -T wordpress sh -c 'command -v wp' &>/dev/null; do
            sleep 3; RETRIES=$((RETRIES - 1))
            [[ $RETRIES -le 0 ]] && { warn "容器未就绪，跳过 wp-config.php 生成"; break; }
        done

        if dc "$DIR" exec -T wordpress sh -c 'command -v wp' &>/dev/null; then
            dc "$DIR" exec -T wordpress wp --allow-root config create \
                --dbname="$DB_NAME" --dbuser="$DB_USER" \
                --dbpass="$DB_PW"   --dbhost="$DB_HOST" \
                --dbcharset=utf8mb4 --path=/var/www/html \
                --extra-php='define("WP_MEMORY_LIMIT","512M");' \
                --skip-check 2>/dev/null \
            && dc "$DIR" exec -T wordpress sh -c \
                "echo \"require_once('/etc/wordpress/wp-config-extra.php');\" >> /var/www/html/wp-config.php" \
            && dc "$DIR" exec -T wordpress cp /var/www/html/wp-config.php /tmp/wp-config-out.php \
            && docker cp "$(dc "$DIR" ps -q wordpress):/tmp/wp-config-out.php" \
                "$DIR/conf/wp-config.php" \
            && log "wp-config.php 已生成并导出至 conf/" \
            || warn "wp-config.php 生成失败，请手动创建或稍后重试（菜单 11）"
        fi
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
}

# ════════════════════════════════════════════════════════
# 镜像回滚（与 v4.3 一致）
# ════════════════════════════════════════════════════════
cmd_rollback() {
    header "镜像回滚"
    read -rp "部署目录 [默认: ${DEFAULT_DIR}]: " DIR; DIR="${DIR:-$DEFAULT_DIR}"
    [[ -f "$DIR/.env" ]] || error "未找到 .env：${DIR}"

    local REGISTRY_HOST; REGISTRY_HOST=$(env_get "$DIR/.env" "REGISTRY_HOST")
    [[ -z "$REGISTRY_HOST" ]] && error ".env 中缺少 REGISTRY_HOST"

    local REG_USER REG_PASS
    if [[ -f "$REGISTRY_DIR/.env" ]]; then
        REG_USER=$(env_get "$REGISTRY_DIR/.env" "REGISTRY_USER")
        REG_PASS=$(env_get "$REGISTRY_DIR/.env" "REGISTRY_PASS")
    else
        read -rp "仓库用户名: " REG_USER; read_secret "仓库密码: " REG_PASS
    fi

    local TAGS_JSON
    TAGS_JSON=$(curl -sf -u "${REG_USER}:${REG_PASS}" \
        "http://${REGISTRY_HOST}/v2/wordpress-site/tags/list" 2>/dev/null)
    if [[ -z "$TAGS_JSON" ]]; then
        warn "无法从仓库获取标签列表"; return
    fi
    local TAGS
    TAGS=$(echo "$TAGS_JSON" | jq -r '.tags[]' | grep -v '^latest$' | sort -r)
    [[ -z "$TAGS" ]] && { warn "仓库中无可用版本"; return; }

    echo ""; echo "可用版本："
    local i=1; local -a TAG_ARR
    while IFS= read -r TAG; do
        echo "  ${i}. ${TAG}"; TAG_ARR+=("$TAG"); i=$((i+1))
    done <<< "$TAGS"

    read -rp "选择版本编号: " TAG_IDX
    [[ "$TAG_IDX" =~ ^[0-9]+$ ]] || error "无效编号"
    local SELECTED_TAG="${TAG_ARR[$((TAG_IDX-1))]}"
    [[ -z "$SELECTED_TAG" ]] && error "无效选择"

    warn "将回滚到版本: ${SELECTED_TAG}"
    read -rp "确认？[y/N]: " CONFIRM
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
# 运维命令（与 v4.3 一致）
# ════════════════════════════════════════════════════════
cmd_status() {
    read -rp "目录 [默认: ${DEFAULT_DIR}]: " DIR; DIR="${DIR:-$DEFAULT_DIR}"
    [[ -f "$DIR/docker-compose.yml" ]] || error "未找到编排文件"
    dc "$DIR" ps; echo ""
    local WP_VER
    WP_VER=$(dc "$DIR" exec -T wordpress \
        cat /var/www/html/wp-includes/version.php 2>/dev/null \
        | grep -oP "(?<=wp_version = ')[^']+") || WP_VER="未知"
    echo -e "  WordPress 版本: \e[36m${WP_VER}\e[0m"
    echo -e "  当前镜像版本:   \e[32m$(env_get "$DIR/.env" IMAGE_TAG)\e[0m"
    echo -e "  仓库地址:       \e[36m$(env_get "$DIR/.env" REGISTRY_HOST)\e[0m"
}

cmd_logs() {
    read -rp "目录 [默认: ${DEFAULT_DIR}]: " DIR; DIR="${DIR:-$DEFAULT_DIR}"
    [[ -f "$DIR/docker-compose.yml" ]] || error "未找到编排文件"
    echo "  1. 容器总日志  2. Nginx 访问日志  3. Nginx 错误日志"
    read -rp "选择 [默认: 1]: " LOG_CHOICE
    case "${LOG_CHOICE:-1}" in
        2) dc "$DIR" exec -T wordpress tail -f /var/log/nginx/access.log ;;
        3) dc "$DIR" exec -T wordpress tail -f /var/log/nginx/error.log ;;
        *) dc "$DIR" logs -f --tail=100 wordpress ;;
    esac
}

cmd_stop()    { read -rp "目录 [默认: ${DEFAULT_DIR}]: " DIR; DIR="${DIR:-$DEFAULT_DIR}"; [[ -f "$DIR/docker-compose.yml" ]] || error "未找到编排文件"; dc "$DIR" stop    && log "已停止。"; }
cmd_start()   { read -rp "目录 [默认: ${DEFAULT_DIR}]: " DIR; DIR="${DIR:-$DEFAULT_DIR}"; [[ -f "$DIR/docker-compose.yml" ]] || error "未找到编排文件"; dc "$DIR" up -d   && log "已启动。"; }
cmd_restart() { read -rp "目录 [默认: ${DEFAULT_DIR}]: " DIR; DIR="${DIR:-$DEFAULT_DIR}"; [[ -f "$DIR/docker-compose.yml" ]] || error "未找到编排文件"; dc "$DIR" restart && log "已重启。"; }

cmd_destroy() {
    read -rp "目录 [默认: ${DEFAULT_DIR}]: " DIR; DIR="${DIR:-$DEFAULT_DIR}"
    [[ -f "$DIR/docker-compose.yml" ]] || error "未找到编排文件"
    warn "将停止容器并删除全部数据（不可恢复）。"
    read -rp "输入 'yes' 确认: " CONFIRM
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
    read -rp "目录 [默认: ${DEFAULT_DIR}]: " DIR; DIR="${DIR:-$DEFAULT_DIR}"
    [[ -f "$DIR/docker-compose.yml" ]] || error "未找到编排文件"
    dc "$DIR" ps --services --filter status=running | grep -q "wordpress" \
        || { warn "wordpress 容器未运行，请先启动。"; return; }
    _setup_plugins "$DIR" "false" || warn "插件配置未完全成功。"
}

cmd_flush() {
    read -rp "目录 [默认: ${DEFAULT_DIR}]: " DIR; DIR="${DIR:-$DEFAULT_DIR}"
    [[ -f "$DIR/docker-compose.yml" ]] || error "未找到编排文件"
    _flush_all_caches "$DIR"
}

cmd_nodes() {
    header "节点列表管理"
    echo "  1. 列出所有节点  2. 添加节点  3. 删除节点"
    read -rp "选择: " NODE_CHOICE
    case "$NODE_CHOICE" in
        1) [[ -s "$NODES_FILE" ]] && nl -ba "$NODES_FILE" || warn "节点列表为空：${NODES_FILE}" ;;
        2) read -rp "节点 WireGuard IP: " NEW_IP; [[ -z "$NEW_IP" ]] && error "IP 不能为空"; _register_node "$NEW_IP" ;;
        3) [[ -f "$NODES_FILE" ]] || { warn "节点列表不存在。"; return; }
           nl -ba "$NODES_FILE"; read -rp "输入要删除的行号: " LINE_NUM
           [[ "$LINE_NUM" =~ ^[0-9]+$ ]] || error "无效行号"
           sed -i "${LINE_NUM}d" "$NODES_FILE"; log "已删除第 ${LINE_NUM} 行。" ;;
        *) warn "无效输入" ;;
    esac
}

interactive_menu() {
    while true; do
        echo ""
        _c "1;35" "========================================"
        _c "1;35" "  WordPress 多节点分发管理 v4.4"
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
        echo -e "  \e[32m 6.\e[0m 查看状态（含 WP 版本）"
        echo -e "  \e[32m 7.\e[0m 查看日志"
        echo -e "  \e[32m 8.\e[0m 启动节点"
        echo -e "  \e[32m 9.\e[0m 停止节点"
        echo -e "  \e[32m10.\e[0m 重启节点"
        echo -e "  \e[33m11.\e[0m 重试插件配置"
        echo -e "  \e[33m12.\e[0m 手动刷新全层缓存"
        echo -e "  \e[36m13.\e[0m 节点列表管理"
        echo -e "  \e[31m14.\e[0m 删除节点（不可恢复）"
        echo -e "  \e[36m 0.\e[0m 退出"
        echo "----------------------------------------"
        read -rp "选择: " CHOICE
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
        read -rp "按回车继续..."
        clear
    done
}

check_deps
clear
interactive_menu
