#!/usr/bin/env bash
# ============================================================
# infra-shared.sh — 共享 MariaDB + Redis（仅监听 WireGuard 网口）
#
# 用法:
#   ./infra-shared.sh                            # 交互菜单
#   ./infra-shared.sh deploy  [DIR] [WG_IP] [db|redis|all]
#   ./infra-shared.sh update  [DIR] [db|redis|all]
#   ./infra-shared.sh add-db  [DIR] <DB> <USER> [PW]
#   ./infra-shared.sh del-db  [DIR] <DB> <USER>
#   ./infra-shared.sh clear-db [DIR] <DB>
#   ./infra-shared.sh list-db [DIR]
#   ./infra-shared.sh passwd  [DIR] <USER> [NEW_PW]
#   ./infra-shared.sh backup  [DIR] [DEST] [--rsync] [--alist]
#   ./infra-shared.sh restore [DIR] <SQL文件|rsync://user@host[:port]/path/file|alist:///path/file>
#   ./infra-shared.sh tune-db    [DIR]               # 查看/调整 MariaDB 性能参数
#   ./infra-shared.sh tune-redis [DIR]               # 查看/调整 Redis 性能参数
#   ./infra-shared.sh rsync-push   [DIR] [LOCAL_DIR]   # 推送备份到远端
#   ./infra-shared.sh rsync-pull   [DIR] [LOCAL_DEST]  # 拉取远端备份到本地
#   ./infra-shared.sh rsync-config [DIR]               # 配置/查看远端 rsync 参数
#   ./infra-shared.sh alist-push   [DIR] [LOCAL_DIR]   # 上传备份到 AList 网盘
#   ./infra-shared.sh alist-pull   [DIR] [LOCAL_DEST]  # 从 AList 网盘下载备份
#   ./infra-shared.sh alist-list   [DIR] [REMOTE_PATH] # 列出 AList 网盘备份文件
#   ./infra-shared.sh alist-config [DIR]               # 配置/测试 AList 连接
#   ./infra-shared.sh status  [DIR]
#   ./infra-shared.sh start   [DIR] [db|redis]
#   ./infra-shared.sh stop    [DIR] [db|redis]
#   ./infra-shared.sh logs    [DIR] <db|redis>
#   ./infra-shared.sh help
# ============================================================
set -euo pipefail
export LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8

# ── 默认值 ──────────────────────────────────────────────────
DEFAULT_DIR="${BASE_DIR:-/srv}/infra"
WG_IFACE="${WG_IFACE:-wg0}"
MARIADB_PORT="${MARIADB_PORT:-3306}"
REDIS_PORT="${REDIS_PORT:-6379}"
MARIADB_IMAGE="${MARIADB_IMAGE:-mariadb:11}"
REDIS_IMAGE="${REDIS_IMAGE:-redis:7-alpine}"

# ── 输出 ────────────────────────────────────────────────────
_c()     { printf "\033[%sm%s\033[0m\n" "$1" "$2"; }
log()    { _c "32"   "[OK]  $*"; }
info()   { _c "36"   "[..]  $*"; }
warn()   { _c "33"   "[!!]  $*"; }
error()  { _c "31"   "[EE]  $*"; exit 1; }
header() { echo; _c "1;34" "══ $* ══"; }

# ── 菜单安全调用包装 ─────────────────────────────────────────
# 在菜单流程中调用命令时，error() 的 exit 1 会终止整个脚本。
# _menu_run 在 subshell 中执行命令，捕获失败只打印错误，不退出父进程。
_menu_run() {
    local _exit_code=0
    (
        set -euo pipefail
        "$@"
    ) || _exit_code=$?
    return $_exit_code
}

# ── 工具函数 ─────────────────────────────────────────────────
randpw() {
    local p
    p=$(timeout 5 sh -c "LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom | head -c 32" 2>/dev/null) \
    || p=$(openssl rand -base64 48 | LC_ALL=C tr -dc 'A-Za-z0-9' | head -c 32)
    printf '%s' "$p"
}

get_wg_ip() {
    local ip
    ip=$(ip addr show "${WG_IFACE}" 2>/dev/null \
        | awk '/inet /{gsub(/\/.*/, "", $2); print $2; exit}')
    [[ -n "$ip" ]] || error "无法获取 ${WG_IFACE} IP，请确认 WireGuard 已启动"
    echo "$ip"
}

_check_ipv4() {
    local ip="$1"
    [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || error "IP 格式无效: '${ip}'"
    local IFS='.'; read -ra o <<< "$ip"
    for s in "${o[@]}"; do (( s <= 255 )) || error "IP 段超范围: '${ip}'"; done
}

_check_id()  {
    [[ "$1" =~ ^[A-Za-z0-9_]{1,64}$ ]] \
        || error "$2 只能含字母/数字/下划线，长度 1-64，实际: '$1'"
}

_check_pw() {
    [[ -n "$1" ]]      || error "$2 不能为空"
    [[ "$1" != *"'"* ]] || error "$2 不能含单引号"
    [[ "$1" != *"\\"* ]] || error "$2 不能含反斜杠"
    [[ ${#1} -ge 8 ]]  || error "$2 至少 8 个字符"
}

load_env() {
    [[ -f "$1/.env" ]] || error ".env 不存在: $1/.env"
    chmod 600 "$1/.env" 2>/dev/null || true
    # 允许加载的 key 白名单（防止 .env 被篡改污染关键环境变量）
    local _ALLOWED_KEYS='WG_IP|MARIADB_ROOT_PASSWORD|MARIADB_DATABASE|MARIADB_USER|MARIADB_PASSWORD|REDIS_PASSWORD|DEPLOY_DB|DEPLOY_REDIS|RSYNC_REMOTE|RSYNC_USER|RSYNC_PORT|RSYNC_KEY|RSYNC_REMOTE_DIR|ALIST_MODE|ALIST_MOUNT|ALIST_URL|ALIST_TOKEN|ALIST_REMOTE_DIR|INNODB_BUFFER_POOL_SIZE|INNODB_LOG_FILE_SIZE|INNODB_FLUSH_LOG|MAX_CONNECTIONS|REDIS_MAXMEMORY'
    local key val line
    while IFS= read -r line || [[ -n "$line" ]]; do
        # 跳过注释和空行
        [[ "$line" =~ ^[[:space:]]*# ]] && continue
        [[ "$line" =~ ^[[:space:]]*$ ]] && continue
        # 只接受 KEY=VALUE 格式，key 必须是合法标识符
        if [[ "$line" =~ ^([A-Za-z_][A-Za-z0-9_]*)=(.*)$ ]]; then
            key="${BASH_REMATCH[1]}"
            val="${BASH_REMATCH[2]}"
            # 只导出白名单内的 key
            if [[ "$key" =~ ^($_ALLOWED_KEYS)$ ]]; then
                printf -v "$key" '%s' "$val"
                export "$key"
            fi
        fi
    done < "$1/.env"
}

_env_set() {   # DIR KEY VAL
    local envfile="$1/.env" key="$2" val="$3" tmp
    tmp="${envfile}.tmp.$$"
    if grep -q "^${key}=" "$envfile" 2>/dev/null; then
        # 用 awk 替换，val 通过变量传入，完全避免 sed 特殊字符问题
        awk -v k="$key" -v v="$val" '
            BEGIN { replaced=0 }
            /^[[:space:]]*#/ { print; next }
            $0 ~ "^" k "=" { print k "=" v; replaced=1; next }
            { print }
            END { if (!replaced) print k "=" v }
        ' "$envfile" > "$tmp" && mv "$tmp" "$envfile"
    else
        printf '%s=%s\n' "$key" "$val" >> "$envfile"
    fi
}

_svc_exists() {   # DIR SVC
    grep -q "^  $2:" "$1/docker-compose.yml" 2>/dev/null
}

_docker_subnet() {
    # 优先检查 compose 项目网络（infra_default），fallback 到 bridge
    local s
    s=$(docker network inspect infra_default \
        --format '{{range .IPAM.Config}}{{.Subnet}}{{end}}' 2>/dev/null || true)
    if [[ -z "$s" ]]; then
        s=$(docker network inspect bridge \
            --format '{{range .IPAM.Config}}{{.Subnet}}{{end}}' 2>/dev/null || true)
    fi
    if [[ "$s" =~ ^([0-9]+\.[0-9]+)\. ]]; then
        echo "${BASH_REMATCH[1]}.%"
    else
        warn "无法检测 Docker 网段，使用默认 172.17.%（如授权失败请手动执行 add-db）" >&2
        echo "172.17.%"
    fi
}

# ── 依赖检查 ─────────────────────────────────────────────────
_check_deps() {
    local missing=()
    # 检查核心命令
    for cmd in docker ip awk grep; do
        command -v "$cmd" >/dev/null 2>&1 || missing+=("$cmd")
    done
    # 检查 docker compose 插件（V2）
    if command -v docker >/dev/null 2>&1 && ! docker compose version >/dev/null 2>&1; then
        missing+=("docker compose (插件)")
    fi

    if [[ ${#missing[@]} -gt 0 ]]; then
        error "缺少依赖命令: ${missing[*]}\n请安装后再运行本脚本。\nDocker 安装参考: curl -fsSL https://get.docker.com | sudo bash"
    fi
}

compose_run() { local d="$1"; shift
    docker compose --project-directory "$d" -f "$d/docker-compose.yml" --env-file "$d/.env" "$@"
}

db_exec() { local d="$1"; shift
    compose_run "$d" exec -T -e MYSQL_PWD="${MARIADB_ROOT_PASSWORD}" db mariadb -uroot "$@"
}

db_sql() {   # DIR SQL
    compose_run "$1" exec -T -e MYSQL_PWD="${MARIADB_ROOT_PASSWORD}" \
        db mariadb -uroot < <(printf '%s\n' "$2")
}

db_sql_on() {   # DIR DB SQL  — 直接指定目标库，避免 USE 在 pipe 中失效
    compose_run "$1" exec -T -e MYSQL_PWD="${MARIADB_ROOT_PASSWORD}" \
        db mariadb -uroot "$2" < <(printf '%s\n' "$3")
}

# ════════════════════════════════════════════════════════════
# 配置文件生成
# ════════════════════════════════════════════════════════════
# ── 自动计算调优默认值 ───────────────────────────────────────
# 输出变量（调用方 local 后 eval 或直接在同 subshell 使用）：
#   _AT_BUFFER_POOL   _AT_LOG_FILE   _AT_MAX_CONN   _AT_REDIS_MEM
_auto_tune() {
    # 物理内存（KB → MB）
    local total_kb; total_kb=$(awk '/^MemTotal/{print $2}' /proc/meminfo 2>/dev/null || echo 0)
    local total_mb=$(( total_kb / 1024 ))

    # innodb_buffer_pool_size = 50% 物理内存（专用 DB 主机），最小 256M，最大 8192M
    local bp=$(( total_mb / 2 ))
    (( bp <  256  )) && bp=256
    (( bp > 8192  )) && bp=8192
    _AT_BUFFER_POOL="${bp}M"

    # innodb_log_file_size = buffer_pool / 4，最小 64M，最大 2048M
    local lf=$(( bp / 4 ))
    (( lf <   64 )) && lf=64
    (( lf > 2048 )) && lf=2048
    _AT_LOG_FILE="${lf}M"

    # max_connections 按内存档位梯度
    if   (( total_mb >= 16384 )); then _AT_MAX_CONN=800
    elif (( total_mb >=  8192 )); then _AT_MAX_CONN=500
    elif (( total_mb >=  4096 )); then _AT_MAX_CONN=300
    elif (( total_mb >=  2048 )); then _AT_MAX_CONN=200
    else                               _AT_MAX_CONN=100
    fi

    # redis maxmemory = 15% 物理内存，最小 128M，最大 4096M
    local rm=$(( total_mb * 15 / 100 ))
    (( rm <  128  )) && rm=128
    (( rm > 4096  )) && rm=4096
    _AT_REDIS_MEM="${rm}mb"
}

_write_mariadb_conf() {
    local dir="$1"
    mkdir -p "$dir/mariadb-conf"
    # 运行时参数：优先 .env 中的显式配置，其次自动计算值
    _auto_tune
    load_env "$dir" 2>/dev/null || true
    local buf="${INNODB_BUFFER_POOL_SIZE:-${_AT_BUFFER_POOL}}"
    local log="${INNODB_LOG_FILE_SIZE:-${_AT_LOG_FILE}}"
    local flush="${INNODB_FLUSH_LOG:-2}"
    local conn="${MAX_CONNECTIONS:-${_AT_MAX_CONN}}"
    # 写入配置（heredoc 变量展开，去掉单引号 'INI'）
    cat > "$dir/mariadb-conf/custom.cnf" <<INI
[mysqld]
innodb_buffer_pool_size        = ${buf}
innodb_log_file_size           = ${log}
innodb_flush_log_at_trx_commit = ${flush}
max_connections                = ${conn}
query_cache_type               = 0
character-set-server           = utf8mb4
collation-server               = utf8mb4_unicode_ci
bind-address                   = 0.0.0.0
slow_query_log                 = 1
slow_query_log_file            = /var/lib/mysql/slow.log
long_query_time                = 2
INI
    log "MariaDB 配置: buffer_pool=${buf}  log_file=${log}  flush=${flush}  max_conn=${conn}"
}

_write_redis_conf() {
    local dir="$1"
    mkdir -p "$dir/redis-conf"
    _auto_tune
    load_env "$dir" 2>/dev/null || true
    local maxmem="${REDIS_MAXMEMORY:-${_AT_REDIS_MEM}}"
    cat > "$dir/redis-conf/redis.conf" <<CONF
bind 0.0.0.0
port ${REDIS_PORT}
requirepass ${REDIS_PASSWORD}
save 900 1
save 300 10
save 60 10000
appendonly yes
appendfsync everysec
maxmemory ${maxmem}
maxmemory-policy allkeys-lru
loglevel notice
logfile ""
CONF
    log "Redis 配置: maxmemory=${maxmem}"
}

_write_compose() {
    load_env "$1"
    local has_db="${DEPLOY_DB:-0}" has_redis="${DEPLOY_REDIS:-0}"
    : > "$1/docker-compose.yml"
    echo "services:" >> "$1/docker-compose.yml"

    [[ "$has_db" == "1" ]] && cat >> "$1/docker-compose.yml" <<YAML

  db:
    image: ${MARIADB_IMAGE}
    restart: unless-stopped
    environment:
      MARIADB_ROOT_PASSWORD: \${MARIADB_ROOT_PASSWORD}
      MARIADB_DATABASE:      \${MARIADB_DATABASE}
    volumes:
      - ./db:/var/lib/mysql
      - ./mariadb-conf/custom.cnf:/etc/mysql/conf.d/custom.cnf:ro
    ports:
      - "\${WG_IP}:${MARIADB_PORT}:3306"
    healthcheck:
      test: ["CMD", "healthcheck.sh", "--connect", "--innodb_initialized"]
      interval: 10s
      timeout: 5s
      retries: 10
      start_period: 30s
YAML

    [[ "$has_redis" == "1" ]] && cat >> "$1/docker-compose.yml" <<YAML

  redis:
    image: ${REDIS_IMAGE}
    restart: unless-stopped
    volumes:
      - ./redis:/data
      - ./redis-conf/redis.conf:/etc/redis/redis.conf:ro
    command: redis-server /etc/redis/redis.conf
    ports:
      - "\${WG_IP}:${REDIS_PORT}:${REDIS_PORT}"
    healthcheck:
      test: ["CMD", "redis-cli", "-h", "127.0.0.1", "-a", "\${REDIS_PASSWORD}", "ping"]
      interval: 10s
      timeout: 5s
      retries: 5
YAML
}

# ════════════════════════════════════════════════════════════
# deploy [DIR] [WG_IP] [db|redis|all]
# update [DIR] [db|redis|all]
# ════════════════════════════════════════════════════════════
cmd_deploy() {
    [[ $EUID -eq 0 ]] || error "需要 root 权限"
    local dir="${1:-$DEFAULT_DIR}" wg_ip="${2:-$(get_wg_ip)}" target="${3:-all}"
    _check_ipv4 "$wg_ip"
    ip link show "${WG_IFACE}" &>/dev/null || error "${WG_IFACE} 不存在，请先启动 WireGuard"

    local do_db=0 do_redis=0
    case "$target" in
        db)    do_db=1 ;;
        redis) do_redis=1 ;;
        all)   do_db=1; do_redis=1 ;;
        *)     error "target 须为 db / redis / all" ;;
    esac

    mkdir -p "$dir"
    # 初始化或更新 .env
    [[ -f "$dir/.env" ]] || { cat > "$dir/.env" <<EOF
# 共享基础设施凭据
WG_IP=${wg_ip}
EOF
        chmod 600 "$dir/.env"; }
    chmod 600 "$dir/.env"
    _env_set "$dir" "WG_IP" "$wg_ip"

    if (( do_db )); then
        mkdir -p "$dir/db" "$dir/backup"
        if ! grep -q "^MARIADB_ROOT_PASSWORD=" "$dir/.env" 2>/dev/null; then
            local _root_pw _wp_pw
            _root_pw=$(randpw)
            _wp_pw=$(randpw)
            [[ -n "$_root_pw" && -n "$_wp_pw" ]] || error "随机密码生成失败，请检查 openssl 或 /dev/urandom"
            printf "MARIADB_ROOT_PASSWORD=%s\nMARIADB_DATABASE=wordpress\nMARIADB_USER=wpuser\nMARIADB_PASSWORD=%s\n" \
                "$_root_pw" "$_wp_pw" >> "$dir/.env"
            log "MariaDB 凭据已生成"
        else
            warn "MariaDB 凭据已存在，跳过生成"
        fi
        _env_set "$dir" "DEPLOY_DB" "1"
        _write_mariadb_conf "$dir"
    fi

    if (( do_redis )); then
        mkdir -p "$dir/redis"
        if ! grep -q "^REDIS_PASSWORD=" "$dir/.env" 2>/dev/null; then
            local _redis_pw
            _redis_pw=$(randpw)
            [[ -n "$_redis_pw" ]] || error "随机密码生成失败，请检查 openssl 或 /dev/urandom"
            echo "REDIS_PASSWORD=${_redis_pw}" >> "$dir/.env"
            log "Redis 凭据已生成"
        else
            warn "Redis 凭据已存在，跳过生成"
        fi
        _env_set "$dir" "DEPLOY_REDIS" "1"
        # load_env 后再写 redis.conf，确保 REDIS_PASSWORD 已载入
        load_env "$dir"
        _write_redis_conf "$dir"
    fi

    _write_compose "$dir"

    sysctl -w vm.overcommit_memory=1 >/dev/null 2>&1 || true
    grep -q 'vm.overcommit_memory' /etc/sysctl.conf \
        || echo 'vm.overcommit_memory = 1' >> /etc/sysctl.conf

    local svcs=()
    (( do_db ))    && svcs+=("db")
    (( do_redis )) && svcs+=("redis")

    header "启动: ${svcs[*]}"
    compose_run "$dir" up -d --wait "${svcs[@]}" 2>&1 \
        || error "docker compose up 失败"

    if (( do_db )); then
        load_env "$dir"
        _grant_wg "$dir" "${MARIADB_DATABASE}" "${MARIADB_USER}" "${MARIADB_PASSWORD}" "$wg_ip"
    fi

    compose_run "$dir" ps
    log "部署完成"
    _print_creds "$dir"
}

cmd_update() {
    [[ $EUID -eq 0 ]] || error "需要 root 权限"
    local dir="${1:-$DEFAULT_DIR}" target="${2:-all}"
    load_env "$dir"

    local svcs=()
    case "$target" in
        db)    _svc_exists "$dir" "db"    || error "MariaDB 未部署"; svcs=("db") ;;
        redis) _svc_exists "$dir" "redis" || error "Redis 未部署";   svcs=("redis") ;;
        all)
            _svc_exists "$dir" "db"    && svcs+=("db")
            _svc_exists "$dir" "redis" && svcs+=("redis")
            [[ ${#svcs[@]} -gt 0 ]] || error "没有已部署的服务"
            ;;
        *) error "target 须为 db / redis / all" ;;
    esac

    header "拉取最新镜像: ${svcs[*]}"
    compose_run "$dir" pull "${svcs[@]}"

    for svc in "${svcs[@]}"; do
        info "重建 ${svc}..."
        compose_run "$dir" up -d --wait --no-deps "$svc" 2>&1 \
            || error "${svc} 重建失败"
        log "${svc} 已更新"
    done

    compose_run "$dir" ps
    log "更新完成"
}

# ── MariaDB 授权 ─────────────────────────────────────────────
_grant_wg() {   # DIR DB USER PW [WG_IP]
    local dir="$1" db="$2" user="$3" pw="$4"
    load_env "$dir"
    local wg_ip="${5:-${WG_IP:-$(get_wg_ip)}}"
    local wg_sub="${wg_ip%.*}.%" docker_sub; docker_sub=$(_docker_subnet)
    db_sql "$dir" "
CREATE USER IF NOT EXISTS '${user}'@'${wg_sub}'     IDENTIFIED BY '${pw}';
ALTER  USER               '${user}'@'${wg_sub}'     IDENTIFIED BY '${pw}';
GRANT ALL PRIVILEGES ON \`${db}\`.* TO '${user}'@'${wg_sub}';
CREATE USER IF NOT EXISTS '${user}'@'${docker_sub}' IDENTIFIED BY '${pw}';
ALTER  USER               '${user}'@'${docker_sub}' IDENTIFIED BY '${pw}';
GRANT ALL PRIVILEGES ON \`${db}\`.* TO '${user}'@'${docker_sub}';
FLUSH PRIVILEGES;"
    log "已授权 ${user}@${wg_sub} 和 ${user}@${docker_sub} → ${db}"
}

# ── 凭据打印 ─────────────────────────────────────────────────
_print_creds() {
    load_env "$1"
    echo ""
    echo "┌─── 连接信息 ───────────────────────────────────────────"
    [[ "${DEPLOY_DB:-0}"    == "1" ]] && printf "│  [MariaDB]  %s:%s  用户:%s  库:%s\n│  密码: %s\n│\n" \
        "$WG_IP" "$MARIADB_PORT" "$MARIADB_USER" "$MARIADB_DATABASE" "$MARIADB_PASSWORD"
    [[ "${DEPLOY_REDIS:-0}" == "1" ]] && printf "│  [Redis]    %s:%s\n│  密码: %s\n│\n" \
        "$WG_IP" "$REDIS_PORT" "$REDIS_PASSWORD"
    echo "│  凭据文件: $1/.env"
    echo "└────────────────────────────────────────────────────────"
    warn "请通过 WireGuard 安全传输 .env 到各节点"
}

# ════════════════════════════════════════════════════════════
# 数据库管理
# ════════════════════════════════════════════════════════════
cmd_add_db() {
    local dir="${1:-$DEFAULT_DIR}" db="${2:?用法: add-db [DIR] <DB> <USER> [PW]}" user="${3:?}" pw="${4:-$(randpw)}"
    _check_id "$db" "数据库名"; _check_id "$user" "用户名"; _check_pw "$pw" "密码"
    _svc_exists "$dir" "db" || error "MariaDB 未部署"
    load_env "$dir"
    local wg_sub="${WG_IP%.*}.%" docker_sub; docker_sub=$(_docker_subnet)
    header "新建数据库: ${db} / 用户: ${user}"
    db_sql "$dir" "
CREATE DATABASE IF NOT EXISTS \`${db}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS '${user}'@'${wg_sub}'     IDENTIFIED BY '${pw}';
ALTER  USER               '${user}'@'${wg_sub}'     IDENTIFIED BY '${pw}';
GRANT ALL PRIVILEGES ON \`${db}\`.* TO '${user}'@'${wg_sub}';
CREATE USER IF NOT EXISTS '${user}'@'${docker_sub}' IDENTIFIED BY '${pw}';
ALTER  USER               '${user}'@'${docker_sub}' IDENTIFIED BY '${pw}';
GRANT ALL PRIVILEGES ON \`${db}\`.* TO '${user}'@'${docker_sub}';
FLUSH PRIVILEGES;"
    log "库: ${db}  用户: ${user}  密码: ${pw}  主机: ${WG_IP}:${MARIADB_PORT:-3306}"
}

cmd_del_db() {
    local dir="${1:-$DEFAULT_DIR}" db="${2:?用法: del-db [DIR] <DB> <USER>}" user="${3:?}"
    _check_id "$db" "数据库名"; _check_id "$user" "用户名"
    _svc_exists "$dir" "db" || error "MariaDB 未部署"
    load_env "$dir"
    local wg_sub="${WG_IP%.*}.%" docker_sub; docker_sub=$(_docker_subnet)
    warn "即将删除库 ${db} 和用户 ${user}，不可逆！"
    read -rp "输入库名确认: " c; [[ "$c" == "$db" ]] || { info "已取消"; return; }
    db_sql "$dir" "
DROP DATABASE IF EXISTS \`${db}\`;
DROP USER IF EXISTS '${user}'@'${wg_sub}';
DROP USER IF EXISTS '${user}'@'${docker_sub}';
FLUSH PRIVILEGES;"
    log "已删除库 ${db} 和用户 ${user}"
}

cmd_clear_db() {
    local dir="${1:-$DEFAULT_DIR}" db="${2:?用法: clear-db [DIR] <DB>}"
    _check_id "$db" "数据库名"
    _svc_exists "$dir" "db" || error "MariaDB 未部署"
    load_env "$dir"
    warn "即将清空库 ${db} 内所有表（库和权限保留），不可逆！"
    read -rp "输入库名确认: " c; [[ "$c" == "$db" ]] || { info "已取消"; return; }

    local tables
    tables=$(db_exec "$dir" -sN -e \
        "SELECT table_name FROM information_schema.tables WHERE table_schema='${db}';")
    [[ -n "$tables" ]] || { info "库 ${db} 无表，无需清空"; return; }

    local drop_sql="SET FOREIGN_KEY_CHECKS=0;"
    while IFS= read -r t; do
        [[ -n "$t" ]] || continue
        # 过滤非法表名，防止查询结果被注入
        [[ "$t" =~ ^[A-Za-z0-9_\$]{1,64}$ ]] || { warn "跳过非法表名: '${t}'"; continue; }
        # 反引号转义：` => ``（MySQL 标识符转义规范）
        local escaped_t="${t//\`/\`\`}"
        drop_sql+=" DROP TABLE IF EXISTS \`${escaped_t}\`;"
    done <<< "$tables"
    drop_sql+=" SET FOREIGN_KEY_CHECKS=1;"

    db_sql_on "$dir" "$db" "$drop_sql"
    log "已清空库 ${db}（$(echo "$tables" | wc -l) 张表）"
}

cmd_list_db() {
    local dir="${1:-$DEFAULT_DIR}"
    _svc_exists "$dir" "db" || error "MariaDB 未部署"
    load_env "$dir"
    header "数据库列表"
    db_exec "$dir" -e "SELECT schema_name AS '数据库', default_character_set_name AS '字符集'
        FROM information_schema.schemata
        WHERE schema_name NOT IN ('mysql','information_schema','performance_schema','sys');"
    header "用户列表"
    db_exec "$dir" -e "SELECT user AS '用户', host AS '来源',
        GROUP_CONCAT(DISTINCT db) AS '可访问库' FROM mysql.db GROUP BY user, host;"
}

cmd_passwd() {
    local dir="${1:-$DEFAULT_DIR}" user="${2:?用法: passwd [DIR] <USER> [PW]}" pw="${3:-$(randpw)}"
    _check_id "$user" "用户名"; _check_pw "$pw" "新密码"
    _svc_exists "$dir" "db" || error "MariaDB 未部署"
    load_env "$dir"
    local hosts
    hosts=$(db_exec "$dir" -sN -e "SELECT host FROM mysql.user WHERE user='${user}';")
    [[ -n "$hosts" ]] || { warn "未找到用户 ${user}"; return 1; }
    while IFS= read -r h; do
        [[ -n "$h" ]] || continue
        db_exec "$dir" -e "ALTER USER '${user}'@'${h}' IDENTIFIED BY '${pw}';"
        log "已更新 ${user}@${h}"
    done <<< "$hosts"
    db_exec "$dir" -e "FLUSH PRIVILEGES;"
    log "新密码: ${pw}"
}

# ════════════════════════════════════════════════════════════
# 性能调优子命令
# ════════════════════════════════════════════════════════════

# tune-db [DIR] — 交互式查看/修改 MariaDB 调优参数
cmd_tune_db() {
    local dir="${1:-$DEFAULT_DIR}"
    [[ -f "$dir/.env" ]] || error ".env 不存在: ${dir}/.env"
    _auto_tune
    load_env "$dir"

    local buf="${INNODB_BUFFER_POOL_SIZE:-${_AT_BUFFER_POOL}}"
    local log="${INNODB_LOG_FILE_SIZE:-${_AT_LOG_FILE}}"
    local flush="${INNODB_FLUSH_LOG:-2}"
    local conn="${MAX_CONNECTIONS:-${_AT_MAX_CONN}}"

    local total_kb; total_kb=$(awk '/^MemTotal/{print $2}' /proc/meminfo 2>/dev/null || echo 0)
    local total_mb=$(( total_kb / 1024 ))

    header "MariaDB 性能参数  （系统内存: ${total_mb}MB）"
    printf "  %-35s %s\n" "innodb_buffer_pool_size"        "${buf}  （自动推荐: ${_AT_BUFFER_POOL}）"
    printf "  %-35s %s\n" "innodb_log_file_size"           "${log}  （自动推荐: ${_AT_LOG_FILE}）"
    printf "  %-35s %s\n" "innodb_flush_log_at_trx_commit" "${flush}  （0=最快/不安全 1=最安全 2=折中）"
    printf "  %-35s %s\n" "max_connections"                "${conn}  （自动推荐: ${_AT_MAX_CONN}）"
    echo
    printf "  当前配置文件: %s/mariadb-conf/custom.cnf\n" "$dir"
    [[ -f "$dir/mariadb-conf/custom.cnf" ]] && {
        echo; echo "  ── 当前文件内容 ──"
        sed 's/^/  /' "$dir/mariadb-conf/custom.cnf"
        echo
    }

    read -rp "  是否修改参数？[y/N] " yn
    [[ "${yn,,}" == "y" ]] || return 0

    echo
    echo "  提示：留空保持当前值；输入 auto 恢复为自动计算值"
    echo

    local val
    read -rp "  innodb_buffer_pool_size  [${buf}]: " val
    case "$val" in
        auto|AUTO) _env_set "$dir" "INNODB_BUFFER_POOL_SIZE" ""; buf=$_AT_BUFFER_POOL ;;
        "")        : ;;
        *[0-9][MmGg])  _env_set "$dir" "INNODB_BUFFER_POOL_SIZE" "${val^^}"; buf="${val^^}" ;;
        *)         warn "格式无效（示例: 512M 1G 2048M），跳过" ;;
    esac

    read -rp "  innodb_log_file_size     [${log}]: " val
    case "$val" in
        auto|AUTO) _env_set "$dir" "INNODB_LOG_FILE_SIZE" ""; log=$_AT_LOG_FILE ;;
        "")        : ;;
        *[0-9][MmGg])  _env_set "$dir" "INNODB_LOG_FILE_SIZE" "${val^^}"; log="${val^^}" ;;
        *)         warn "格式无效，跳过" ;;
    esac

    read -rp "  innodb_flush_log (0/1/2) [${flush}]: " val
    case "$val" in
        0|1|2) _env_set "$dir" "INNODB_FLUSH_LOG" "$val"; flush="$val" ;;
        "")    : ;;
        *)     warn "只能输入 0、1 或 2，跳过" ;;
    esac

    read -rp "  max_connections          [${conn}]: " val
    case "$val" in
        auto|AUTO) _env_set "$dir" "MAX_CONNECTIONS" ""; conn=$_AT_MAX_CONN ;;
        "")        : ;;
        [0-9]*)
            if (( val >= 10 && val <= 10000 )); then
                _env_set "$dir" "MAX_CONNECTIONS" "$val"; conn="$val"
            else warn "范围 10-10000，跳过"; fi ;;
        *) warn "需要数字，跳过" ;;
    esac

    # 重写配置文件
    _write_mariadb_conf "$dir"
    log "配置文件已更新: ${dir}/mariadb-conf/custom.cnf"

    # 提示重启
    if _svc_exists "$dir" "db" 2>/dev/null; then
        read -rp "  是否立即重启 MariaDB 使配置生效？[y/N] " yn
        if [[ "${yn,,}" == "y" ]]; then
            compose_run "$dir" restart db \
                && log "MariaDB 已重启" \
                || warn "重启失败，请手动执行: docker compose -f ${dir}/docker-compose.yml restart db"
        else
            warn "配置已写入，请手动重启 MariaDB 生效"
        fi
    fi
}

# tune-redis [DIR] — 交互式查看/修改 Redis 调优参数
cmd_tune_redis() {
    local dir="${1:-$DEFAULT_DIR}"
    [[ -f "$dir/.env" ]] || error ".env 不存在: ${dir}/.env"
    _auto_tune
    load_env "$dir"

    local maxmem="${REDIS_MAXMEMORY:-${_AT_REDIS_MEM}}"
    local total_kb; total_kb=$(awk '/^MemTotal/{print $2}' /proc/meminfo 2>/dev/null || echo 0)
    local total_mb=$(( total_kb / 1024 ))

    header "Redis 性能参数  （系统内存: ${total_mb}MB）"
    printf "  %-20s %s\n" "maxmemory" "${maxmem}  （自动推荐: ${_AT_REDIS_MEM}）"
    echo
    printf "  当前配置文件: %s/redis-conf/redis.conf\n" "$dir"
    [[ -f "$dir/redis-conf/redis.conf" ]] && {
        echo; echo "  ── 当前文件内容 ──"
        grep -v "requirepass" "$dir/redis-conf/redis.conf" | sed 's/^/  /'
        echo
    }

    read -rp "  是否修改参数？[y/N] " yn
    [[ "${yn,,}" == "y" ]] || return 0

    echo
    local val
    read -rp "  maxmemory  [${maxmem}]（示例: 256mb 512mb 1gb，auto=自动推荐）: " val
    case "$val" in
        auto|AUTO) _env_set "$dir" "REDIS_MAXMEMORY" "" ;;
        "")        : ;;
        *[0-9][mMgGbB]*)
            _env_set "$dir" "REDIS_MAXMEMORY" "${val,,}"; maxmem="${val,,}" ;;
        *) warn "格式无效（示例: 512mb），跳过" ;;
    esac

    load_env "$dir"
    _write_redis_conf "$dir"
    log "配置文件已更新: ${dir}/redis-conf/redis.conf"

    if _svc_exists "$dir" "redis" 2>/dev/null; then
        read -rp "  是否立即重启 Redis 使配置生效？[y/N] " yn
        if [[ "${yn,,}" == "y" ]]; then
            compose_run "$dir" restart redis \
                && log "Redis 已重启" \
                || warn "重启失败，请手动执行: docker compose -f ${dir}/docker-compose.yml restart redis"
        else
            warn "配置已写入，请手动重启 Redis 生效"
        fi
    fi
}



# 校验 rsync 依赖
_check_rsync() {
    command -v rsync >/dev/null 2>&1 || error "未找到 rsync，请先安装: apt-get install -y rsync"
    command -v ssh   >/dev/null 2>&1 || error "未找到 ssh，请先安装 openssh-client"
}

# 从 .env 读取 rsync 配置，缺失时报错
_load_rsync_conf() {
    local dir="$1"
    load_env "$dir"
    [[ -n "${RSYNC_REMOTE:-}"     ]] || error "未配置 RSYNC_REMOTE，请先运行 rsync-config"
    [[ -n "${RSYNC_USER:-}"       ]] || error "未配置 RSYNC_USER，请先运行 rsync-config"
    [[ -n "${RSYNC_REMOTE_DIR:-}" ]] || error "未配置 RSYNC_REMOTE_DIR，请先运行 rsync-config"
    RSYNC_PORT="${RSYNC_PORT:-22}"
    RSYNC_KEY="${RSYNC_KEY:-}"
}

# 构建 rsync SSH 选项数组
_rsync_ssh_opts() {
    local key="${RSYNC_KEY:-}" port="${RSYNC_PORT:-22}"
    local ssh_cmd="ssh -p ${port} -o StrictHostKeyChecking=no -o BatchMode=yes"
    [[ -n "$key" ]] && ssh_cmd+=" -i ${key}"
    echo "$ssh_cmd"
}

# 推送本地目录/文件 → 远端目录
# _rsync_push DIR SRC_PATH [REMOTE_DEST_DIR]
_rsync_push() {
    local dir="$1" src="$2" remote_dest="${3:-}"
    _check_rsync
    _load_rsync_conf "$dir"
    [[ -n "$remote_dest" ]] || remote_dest="$RSYNC_REMOTE_DIR"
    local ssh_cmd; ssh_cmd=$(_rsync_ssh_opts)

    info "rsync 推送: ${src} → ${RSYNC_USER}@${RSYNC_REMOTE}:${remote_dest}"
    rsync -avz --progress \
        -e "$ssh_cmd" \
        "$src" \
        "${RSYNC_USER}@${RSYNC_REMOTE}:${remote_dest}" \
        && log "推送完成" \
        || error "rsync 推送失败（退出码 $?）"
}

# 从远端目录拉取文件 → 本地目录
# _rsync_pull DIR REMOTE_SRC LOCAL_DEST
_rsync_pull() {
    local dir="$1" remote_src="$2" local_dest="$3"
    _check_rsync
    _load_rsync_conf "$dir"
    local ssh_cmd; ssh_cmd=$(_rsync_ssh_opts)
    mkdir -p "$local_dest"

    info "rsync 拉取: ${RSYNC_USER}@${RSYNC_REMOTE}:${remote_src} → ${local_dest}"
    rsync -avz --progress \
        -e "$ssh_cmd" \
        "${RSYNC_USER}@${RSYNC_REMOTE}:${remote_src}" \
        "$local_dest/" \
        && log "拉取完成" \
        || error "rsync 拉取失败（退出码 $?）"
}

# 列出远端目录内容
_rsync_list() {
    local dir="$1" remote_path="${2:-}"
    _check_rsync
    _load_rsync_conf "$dir"
    [[ -n "$remote_path" ]] || remote_path="$RSYNC_REMOTE_DIR"
    local ssh_cmd; ssh_cmd=$(_rsync_ssh_opts)
    ssh -p "${RSYNC_PORT}" ${RSYNC_KEY:+-i "$RSYNC_KEY"} \
        -o StrictHostKeyChecking=no -o BatchMode=yes \
        "${RSYNC_USER}@${RSYNC_REMOTE}" \
        "ls -lht '${remote_path}' 2>/dev/null || echo '（目录为空或不存在）'"
}

# 解析 rsync URI: rsync://user@host:port/path/to/file
# 输出: RSYNC_URI_USER  RSYNC_URI_HOST  RSYNC_URI_PORT  RSYNC_URI_PATH
_parse_rsync_uri() {
    local uri="$1"
    # rsync://user@host:port/path  or  rsync://user@host/path
    if [[ "$uri" =~ ^rsync://([^@]+)@([^:/]+)(:([0-9]+))?(/.*)?$ ]]; then
        RSYNC_URI_USER="${BASH_REMATCH[1]}"
        RSYNC_URI_HOST="${BASH_REMATCH[2]}"
        RSYNC_URI_PORT="${BASH_REMATCH[4]:-22}"
        RSYNC_URI_PATH="${BASH_REMATCH[5]:-/}"
    else
        error "无法解析 rsync URI: '${uri}'  格式: rsync://user@host[:port]/path/file"
    fi
}

# ════════════════════════════════════════════════════════════
# rsync 子命令
# ════════════════════════════════════════════════════════════

# rsync-config [DIR] — 交互式设置或显示当前 rsync 配置
cmd_rsync_config() {
    local dir="${1:-$DEFAULT_DIR}"
    [[ -f "$dir/.env" ]] || error ".env 不存在，请先部署: ${dir}/.env"
    load_env "$dir"

    header "当前 rsync 配置"
    printf "  RSYNC_REMOTE     = %s\n" "${RSYNC_REMOTE:-（未设置）}"
    printf "  RSYNC_USER       = %s\n" "${RSYNC_USER:-（未设置）}"
    printf "  RSYNC_PORT       = %s\n" "${RSYNC_PORT:-22}"
    printf "  RSYNC_KEY        = %s\n" "${RSYNC_KEY:-（使用默认密钥）}"
    printf "  RSYNC_REMOTE_DIR = %s\n" "${RSYNC_REMOTE_DIR:-（未设置）}"
    echo

    read -rp "  是否修改配置？[y/N] " yn
    [[ "${yn,,}" == "y" ]] || return 0

    local val
    read -rp "  远端主机 IP/域名 [${RSYNC_REMOTE:-}]: " val
    [[ -n "$val" ]] && _env_set "$dir" "RSYNC_REMOTE" "$val"

    read -rp "  SSH 用户名 [${RSYNC_USER:-root}]: " val
    [[ -n "$val" ]] && _env_set "$dir" "RSYNC_USER" "$val" || \
        { [[ -z "${RSYNC_USER:-}" ]] && _env_set "$dir" "RSYNC_USER" "root"; }

    read -rp "  SSH 端口 [${RSYNC_PORT:-22}]: " val
    [[ -n "$val" ]] && _env_set "$dir" "RSYNC_PORT" "$val" || \
        { [[ -z "${RSYNC_PORT:-}" ]] && _env_set "$dir" "RSYNC_PORT" "22"; }

    read -rp "  SSH 私钥路径（留空使用默认）[${RSYNC_KEY:-}]: " val
    if [[ -n "$val" ]]; then
        [[ -f "$val" ]] || warn "警告：密钥文件不存在: ${val}"
        _env_set "$dir" "RSYNC_KEY" "$val"
    fi

    read -rp "  远端备份目录 [${RSYNC_REMOTE_DIR:-/backup/infra}]: " val
    if [[ -n "$val" ]]; then
        _env_set "$dir" "RSYNC_REMOTE_DIR" "$val"
    else
        [[ -z "${RSYNC_REMOTE_DIR:-}" ]] && _env_set "$dir" "RSYNC_REMOTE_DIR" "/backup/infra"
    fi

    log "rsync 配置已保存到 ${dir}/.env"

    # 可选：测试连通性
    read -rp "  是否立即测试连通性？[y/N] " yn
    if [[ "${yn,,}" == "y" ]]; then
        load_env "$dir"
        _check_rsync
        local key_opt=(); [[ -n "${RSYNC_KEY:-}" ]] && key_opt=(-i "$RSYNC_KEY")
        if ssh -p "${RSYNC_PORT:-22}" "${key_opt[@]}" \
               -o StrictHostKeyChecking=no -o BatchMode=yes \
               -o ConnectTimeout=10 \
               "${RSYNC_USER}@${RSYNC_REMOTE}" "echo OK" 2>/dev/null | grep -q OK; then
            log "✓ SSH 连通正常"
        else
            warn "✗ SSH 连接失败，请检查主机/用户/密钥/端口配置"
        fi
    fi
}

# rsync-push [DIR] [LOCAL_DIR]
cmd_rsync_push() {
    local dir="${1:-$DEFAULT_DIR}" local_dir="${2:-${1:-$DEFAULT_DIR}/backup}"
    [[ -d "$local_dir" ]] || error "本地目录不存在: ${local_dir}"
    load_env "$dir"
    header "推送备份 → 远端"
    _rsync_push "$dir" "${local_dir%/}/" ""
}

# rsync-pull [DIR] [LOCAL_DEST]
cmd_rsync_pull() {
    local dir="${1:-$DEFAULT_DIR}" local_dest="${2:-${1:-$DEFAULT_DIR}/backup/remote}"
    load_env "$dir"
    header "拉取远端备份 → ${local_dest}"
    _load_rsync_conf "$dir"
    _rsync_pull "$dir" "${RSYNC_REMOTE_DIR%/}/" "$local_dest"
    log "文件已拉取到: ${local_dest}"
}

# ════════════════════════════════════════════════════════════
# AList 网盘工具函数
# ════════════════════════════════════════════════════════════
# 支持两种模式（ALIST_MODE）：
#   mount  — AList 已通过 FUSE/rclone 挂载为本地目录（ALIST_MOUNT），
#            直接用 cp/rsync 操作，无需网络凭证
#   webdav — 通过 AList WebDAV 接口上传/下载，需要 ALIST_URL + ALIST_TOKEN，
#            依赖 curl；不需要 FUSE 挂载权限

_check_alist_deps() {
    local mode="${ALIST_MODE:-mount}"
    if [[ "$mode" == "webdav" ]]; then
        command -v curl >/dev/null 2>&1 || error "webdav 模式需要 curl，请安装: apt-get install -y curl"
    else
        command -v rsync >/dev/null 2>&1 || error "mount 模式需要 rsync，请安装: apt-get install -y rsync"
    fi
}

# 从 .env 读取 AList 配置并校验
_load_alist_conf() {
    local dir="$1"
    load_env "$dir"
    ALIST_MODE="${ALIST_MODE:-mount}"
    ALIST_REMOTE_DIR="${ALIST_REMOTE_DIR:-/backup/infra}"
    case "$ALIST_MODE" in
        mount)
            [[ -n "${ALIST_MOUNT:-}" ]] || error "mount 模式需要配置 ALIST_MOUNT（本地挂载点），请运行 alist-config"
            ;;
        webdav)
            [[ -n "${ALIST_URL:-}"   ]] || error "webdav 模式需要配置 ALIST_URL，请运行 alist-config"
            [[ -n "${ALIST_TOKEN:-}" ]] || error "webdav 模式需要配置 ALIST_TOKEN，请运行 alist-config"
            # 去掉末尾斜杠
            ALIST_URL="${ALIST_URL%/}"
            ;;
        *) error "ALIST_MODE 只能为 mount 或 webdav，当前: '${ALIST_MODE}'" ;;
    esac
}

# 检测挂载点是否活跃（mount 模式）
_alist_check_mount() {
    local mnt="$1"
    [[ -d "$mnt" ]] || error "AList 挂载目录不存在: ${mnt}"
    # 尝试列出目录，判断 FUSE 是否正常工作
    if ! timeout 5 ls "$mnt" >/dev/null 2>&1; then
        error "AList 挂载点无响应: ${mnt}  请检查 AList 进程和 FUSE 挂载状态"
    fi
}

# WebDAV：向 AList 发送请求，返回 HTTP 状态码
# _alist_curl METHOD PATH [-o FILE | --data-binary @FILE | ...]
_alist_curl() {
    local method="$1" path="$2"; shift 2
    local url="${ALIST_URL}/dav${path}"
    curl -s -o /dev/null -w "%{http_code}" \
        -X "$method" \
        -H "Authorization: Basic $(printf '%s' ":${ALIST_TOKEN}" | base64 -w0)" \
        "$@" \
        "$url"
}

# WebDAV：创建远端目录（MKCOL，忽略 405 已存在）
_alist_mkdir_webdav() {
    local path="$1"
    local code; code=$(_alist_curl MKCOL "$path")
    [[ "$code" == "201" || "$code" == "405" || "$code" == "301" ]] \
        || warn "创建目录 ${path} 返回 HTTP ${code}（可能已存在，继续）"
}

# WebDAV：上传单文件
# _alist_upload_webdav LOCAL_FILE REMOTE_PATH
_alist_upload_webdav() {
    local local_file="$1" remote_path="$2"
    local fname; fname=$(basename "$local_file")
    local url="${ALIST_URL}/dav${remote_path%/}/${fname}"
    local code
    code=$(curl -s -o /dev/null -w "%{http_code}" \
        -X PUT \
        -H "Authorization: Basic $(printf '%s' ":${ALIST_TOKEN}" | base64 -w0)" \
        -H "Content-Type: application/octet-stream" \
        --data-binary "@${local_file}" \
        "$url")
    [[ "$code" == "200" || "$code" == "201" || "$code" == "204" ]] \
        || error "上传 ${fname} 失败，HTTP ${code}（URL: ${url}）"
    log "✓ 上传: ${fname}  HTTP ${code}"
}

# WebDAV：下载单文件到本地目录
# _alist_download_webdav REMOTE_FILE_PATH LOCAL_DIR
_alist_download_webdav() {
    local remote_path="$1" local_dir="$2"
    local fname; fname=$(basename "$remote_path")
    local url="${ALIST_URL}/dav${remote_path}"
    local out="${local_dir}/${fname}"
    local code
    code=$(curl -s -w "%{http_code}" \
        -X GET \
        -H "Authorization: Basic $(printf '%s' ":${ALIST_TOKEN}" | base64 -w0)" \
        -o "$out" \
        "$url")
    [[ "$code" == "200" || "$code" == "206" ]] \
        || { rm -f "$out"; error "下载 ${fname} 失败，HTTP ${code}"; }
    log "✓ 下载: ${fname}  ($(du -sh "$out" | cut -f1))"
}

# WebDAV：列出远端目录（PROPFIND），输出文件名列表
_alist_list_webdav() {
    local remote_path="${1:-$ALIST_REMOTE_DIR}"
    local url="${ALIST_URL}/dav${remote_path}"
    local body
    body=$(curl -s \
        -X PROPFIND \
        -H "Authorization: Basic $(printf '%s' ":${ALIST_TOKEN}" | base64 -w0)" \
        -H "Depth: 1" \
        -H "Content-Type: application/xml" \
        --data '<?xml version="1.0"?><D:propfind xmlns:D="DAV:"><D:prop><D:displayname/><D:getcontentlength/><D:getlastmodified/></D:prop></D:propfind>' \
        "$url" 2>/dev/null) || { warn "无法连接 AList WebDAV: ${url}"; return 1; }

    # 解析 href，过滤掉目录本身，只显示 .sql.gz / .sql 文件
    echo "$body" \
        | grep -oP '(?<=<D:href>)[^<]+' \
        | grep -E '\.(sql|sql\.gz)$' \
        | sed 's|.*/dav||' \
        | while read -r p; do printf "  %s\n" "$p"; done
}

# ── 统一对外接口：上传目录下所有 .sql.gz 文件到 AList ────────
# _alist_push DIR LOCAL_DIR [REMOTE_SUBDIR]
_alist_push() {
    local dir="$1" local_dir="$2" remote_sub="${3:-}"
    _load_alist_conf "$dir"
    _check_alist_deps
    local remote_dir="${ALIST_REMOTE_DIR%/}${remote_sub:+/${remote_sub}}"

    case "$ALIST_MODE" in
    mount)
        _alist_check_mount "$ALIST_MOUNT"
        local dest_dir="${ALIST_MOUNT%/}/${remote_dir#/}"
        mkdir -p "$dest_dir" 2>/dev/null \
            || warn "无法在挂载点创建目录（某些只读网盘正常），继续尝试..."
        header "AList 挂载上传: ${local_dir} → ${dest_dir}"
        # --no-perms --no-owner：FUSE 文件系统不支持权限操作
        rsync -av --no-perms --no-owner --no-group \
              --include='*.sql.gz' --include='*.sql' --exclude='*' \
              "${local_dir%/}/" "${dest_dir%/}/" \
            && log "上传完成 → ${dest_dir}" \
            || error "rsync 到 AList 挂载目录失败"
        ;;
    webdav)
        header "AList WebDAV 上传: ${local_dir} → ${ALIST_URL}/dav${remote_dir}"
        _alist_mkdir_webdav "$remote_dir"
        local f failed=0
        while IFS= read -r -d '' f; do
            _alist_upload_webdav "$f" "$remote_dir" || (( failed++ )) || true
        done < <(find "$local_dir" -maxdepth 1 \( -name '*.sql.gz' -o -name '*.sql' \) -print0)
        (( failed == 0 )) && log "全部上传完成" || { warn "${failed} 个文件上传失败"; return 1; }
        ;;
    esac
}

# ── 统一对外接口：从 AList 下载备份文件到本地目录 ─────────────
# _alist_pull DIR LOCAL_DEST [REMOTE_SUBDIR]
_alist_pull() {
    local dir="$1" local_dest="$2" remote_sub="${3:-}"
    _load_alist_conf "$dir"
    _check_alist_deps
    local remote_dir="${ALIST_REMOTE_DIR%/}${remote_sub:+/${remote_sub}}"
    mkdir -p "$local_dest"

    case "$ALIST_MODE" in
    mount)
        _alist_check_mount "$ALIST_MOUNT"
        local src_dir="${ALIST_MOUNT%/}/${remote_dir#/}"
        [[ -d "$src_dir" ]] || error "AList 挂载中找不到目录: ${src_dir}"
        header "AList 挂载下载: ${src_dir} → ${local_dest}"
        rsync -av --no-perms --no-owner --no-group \
              --include='*.sql.gz' --include='*.sql' --exclude='*' \
              "${src_dir%/}/" "${local_dest%/}/" \
            && log "下载完成 → ${local_dest}" \
            || error "rsync 从 AList 挂载目录失败"
        ;;
    webdav)
        header "AList WebDAV 下载: ${ALIST_URL}/dav${remote_dir} → ${local_dest}"
        # 先列出文件列表，逐个下载
        local files; files=$(_alist_list_webdav "$remote_dir" 2>/dev/null) \
            || error "无法列出 AList 远端目录: ${remote_dir}"
        [[ -n "$files" ]] || { warn "远端目录为空: ${remote_dir}"; return 0; }
        local f failed=0
        while IFS= read -r f; do
            f="${f#"${f%%[![:space:]]*}"}"  # trim leading spaces
            [[ -n "$f" ]] || continue
            _alist_download_webdav "$f" "$local_dest" || (( failed++ )) || true
        done <<< "$files"
        (( failed == 0 )) && log "全部下载完成 → ${local_dest}" \
            || { warn "${failed} 个文件下载失败"; return 1; }
        ;;
    esac
}

# ── 列出 AList 远端备份目录内容 ──────────────────────────────
_alist_list() {
    local dir="$1" remote_path="${2:-}"
    _load_alist_conf "$dir"
    [[ -n "$remote_path" ]] || remote_path="$ALIST_REMOTE_DIR"

    case "$ALIST_MODE" in
    mount)
        _alist_check_mount "$ALIST_MOUNT"
        local src="${ALIST_MOUNT%/}/${remote_path#/}"
        [[ -d "$src" ]] || { warn "目录不存在: ${src}"; return 0; }
        ls -lht "$src" 2>/dev/null | grep -E '\.(sql|sql\.gz)$' \
            || warn "（目录为空或无备份文件）"
        ;;
    webdav)
        _check_alist_deps
        local files; files=$(_alist_list_webdav "$remote_path")
        [[ -n "$files" ]] && echo "$files" || warn "（目录为空或无备份文件）"
        ;;
    esac
}

# ── 从 AList 拉取单个文件（alist:///path/file.sql.gz URI）────
# 下载到临时目录，返回本地路径到 stdout
_alist_fetch_file() {
    local dir="$1" remote_file="$2"  # remote_file = AList 内部路径，如 /backup/infra/mydb_20250101.sql.gz
    _load_alist_conf "$dir"
    _check_alist_deps
    local tmp_dir; tmp_dir=$(mktemp -d)
    local fname; fname=$(basename "$remote_file")

    case "$ALIST_MODE" in
    mount)
        _alist_check_mount "$ALIST_MOUNT"
        local src="${ALIST_MOUNT%/}/${remote_file#/}"
        [[ -f "$src" ]] || { rm -rf "$tmp_dir"; error "AList 挂载中找不到文件: ${src}"; }
        cp "$src" "${tmp_dir}/${fname}" \
            || { rm -rf "$tmp_dir"; error "从 AList 挂载复制文件失败"; }
        ;;
    webdav)
        _alist_download_webdav "$remote_file" "$tmp_dir" \
            || { rm -rf "$tmp_dir"; error "从 AList WebDAV 下载文件失败"; }
        ;;
    esac
    echo "${tmp_dir}/${fname}"
}

# ════════════════════════════════════════════════════════════
# AList 子命令
# ════════════════════════════════════════════════════════════

# alist-config [DIR] — 交互式配置 AList 参数
cmd_alist_config() {
    local dir="${1:-$DEFAULT_DIR}"
    [[ -f "$dir/.env" ]] || error ".env 不存在，请先部署: ${dir}/.env"
    load_env "$dir"

    header "当前 AList 配置"
    printf "  ALIST_MODE       = %s\n" "${ALIST_MODE:-mount}"
    printf "  ALIST_MOUNT      = %s\n" "${ALIST_MOUNT:-（未设置，mount 模式需要）}"
    printf "  ALIST_URL        = %s\n" "${ALIST_URL:-（未设置，webdav 模式需要）}"
    printf "  ALIST_TOKEN      = %s\n" "${ALIST_TOKEN:+***已设置***}${ALIST_TOKEN:-（未设置，webdav 模式需要）}"
    printf "  ALIST_REMOTE_DIR = %s\n" "${ALIST_REMOTE_DIR:-/backup/infra}"
    echo

    read -rp "  是否修改配置？[y/N] " yn
    [[ "${yn,,}" == "y" ]] || return 0

    echo
    echo "  AList 支持两种接入模式："
    echo "  [1] mount  — AList 已挂载为本地 FUSE 目录（推荐，速度快）"
    echo "  [2] webdav — 通过 AList WebDAV HTTP 接口传输（无需挂载）"
    read -rp "  选择模式 [1=mount/2=webdav，当前: ${ALIST_MODE:-mount}]: " sel
    case "$sel" in
        1) _env_set "$dir" "ALIST_MODE" "mount"  ;;
        2) _env_set "$dir" "ALIST_MODE" "webdav" ;;
        "") : ;;  # 保持不变
        *) warn "无效选择，保持原值" ;;
    esac
    load_env "$dir"  # 重新加载获取刚写入的 MODE

    local val
    if [[ "${ALIST_MODE:-mount}" == "mount" ]]; then
        read -rp "  本地挂载点路径 [${ALIST_MOUNT:-/mnt/alist}]: " val
        if [[ -n "$val" ]]; then
            _env_set "$dir" "ALIST_MOUNT" "$val"
        elif [[ -z "${ALIST_MOUNT:-}" ]]; then
            _env_set "$dir" "ALIST_MOUNT" "/mnt/alist"
        fi
    else
        read -rp "  AList 服务地址（含端口，如 http://127.0.0.1:5244）[${ALIST_URL:-}]: " val
        [[ -n "$val" ]] && _env_set "$dir" "ALIST_URL" "${val%/}"

        echo "  AList Token 获取方式："
        echo "  方式一（推荐）：AList 管理页 → 用户 → 生成 Token"
        echo "  方式二：AList 管理员密码（WebDAV Basic Auth 使用 guest:password 或 admin:password）"
        read -rsp "  AList Token / 密码（输入不回显）: " val; echo
        [[ -n "$val" ]] && _env_set "$dir" "ALIST_TOKEN" "$val"
    fi

    read -rp "  AList 内备份目录（AList 路径，如 /onedrive/backup/infra）[${ALIST_REMOTE_DIR:-/backup/infra}]: " val
    if [[ -n "$val" ]]; then
        _env_set "$dir" "ALIST_REMOTE_DIR" "$val"
    elif [[ -z "${ALIST_REMOTE_DIR:-}" ]]; then
        _env_set "$dir" "ALIST_REMOTE_DIR" "/backup/infra"
    fi

    log "AList 配置已保存到 ${dir}/.env"
    load_env "$dir"

    # 测试连通性
    read -rp "  是否立即测试连通性？[y/N] " yn
    if [[ "${yn,,}" == "y" ]]; then
        _load_alist_conf "$dir"
        case "$ALIST_MODE" in
        mount)
            if timeout 5 ls "$ALIST_MOUNT" >/dev/null 2>&1; then
                log "✓ 挂载点响应正常: ${ALIST_MOUNT}"
                ls -lh "$ALIST_MOUNT" 2>/dev/null | head -5 || true
            else
                warn "✗ 挂载点无响应: ${ALIST_MOUNT}，请检查 AList 和 FUSE 挂载状态"
            fi
            ;;
        webdav)
            _check_alist_deps
            local code
            code=$(curl -s -o /dev/null -w "%{http_code}" \
                -X PROPFIND \
                -H "Authorization: Basic $(printf '%s' ":${ALIST_TOKEN}" | base64 -w0)" \
                -H "Depth: 0" \
                --connect-timeout 8 \
                "${ALIST_URL}/dav/")
            if [[ "$code" == "207" || "$code" == "200" ]]; then
                log "✓ AList WebDAV 连接正常（HTTP ${code}）"
            else
                warn "✗ AList WebDAV 连接失败（HTTP ${code}）  URL: ${ALIST_URL}/dav/"
                warn "  请确认 AList 已启动、URL 正确、Token 有效"
            fi
            ;;
        esac
    fi
}

# alist-push [DIR] [LOCAL_DIR]
cmd_alist_push() {
    local dir="${1:-$DEFAULT_DIR}" local_dir="${2:-${1:-$DEFAULT_DIR}/backup}"
    [[ -d "$local_dir" ]] || error "本地目录不存在: ${local_dir}"
    header "上传备份到 AList 网盘"
    _alist_push "$dir" "$local_dir"
}

# alist-pull [DIR] [LOCAL_DEST]
cmd_alist_pull() {
    local dir="${1:-$DEFAULT_DIR}" local_dest="${2:-${1:-$DEFAULT_DIR}/backup/alist}"
    header "从 AList 网盘下载备份 → ${local_dest}"
    _alist_pull "$dir" "$local_dest"
    log "文件已下载到: ${local_dest}"
}

# alist-list [DIR] [REMOTE_PATH]
cmd_alist_list() {
    local dir="${1:-$DEFAULT_DIR}" remote_path="${2:-}"
    load_env "$dir"
    header "AList 网盘备份文件列表"
    _alist_list "$dir" "$remote_path"
}


# ════════════════════════════════════════════════════════════
# 备份 / 恢复
# ════════════════════════════════════════════════════════════
# cmd_backup [DIR] [DEST] [--rsync] [--alist]
#   --rsync : 备份完成后自动推送到 rsync 远端（须已配置 rsync-config）
#   --alist : 备份完成后自动上传到 AList 网盘（须已配置 alist-config）
cmd_backup() {
    local dir="${1:-$DEFAULT_DIR}" dest="${2:-${1:-$DEFAULT_DIR}/backup}" do_rsync=0 do_alist=0
    for _a in "$@"; do
        [[ "$_a" == "--rsync" ]] && do_rsync=1
        [[ "$_a" == "--alist" ]] && do_alist=1
    done

    _svc_exists "$dir" "db" || error "MariaDB 未部署"
    load_env "$dir"; mkdir -p "$dest"
    local ts; ts=$(date +%Y%m%d_%H%M%S)
    header "备份 → ${dest}"
    local dbs failed=0
    dbs=$(db_exec "$dir" -sN -e \
        "SELECT schema_name FROM information_schema.schemata
         WHERE schema_name NOT IN ('mysql','information_schema','performance_schema','sys');")
    while IFS= read -r db; do
        [[ -n "$db" ]] || continue
        local out="${dest}/${db}_${ts}.sql.gz" tmp="${dest}/${db}_${ts}.sql.gz.tmp"
        info "备份 ${db}..."
        if compose_run "$dir" exec -T -e MYSQL_PWD="${MARIADB_ROOT_PASSWORD}" \
                db mariadb-dump -uroot --single-transaction --routines --triggers "${db}" \
            | gzip > "$tmp"; then
            mv "$tmp" "$out"
            log "✓ ${db} ($(du -sh "$out" | cut -f1))"
        else
            rm -f "$tmp"; warn "✗ ${db} 失败"; (( failed++ )) || true
        fi
    done <<< "$dbs"
    (( failed == 0 )) && log "备份完成: ${dest}" || { warn "${failed} 个库失败"; return 1; }

    # ── 可选 rsync 推送 ──────────────────────────────────────
    if (( do_rsync )); then
        header "推送备份到 rsync 远端"
        _rsync_push "$dir" "${dest%/}/" ""
    fi

    # ── 可选 AList 上传 ───────────────────────────────────────
    if (( do_alist )); then
        header "上传备份到 AList 网盘"
        _alist_push "$dir" "$dest"
    fi
}

cmd_restore() {
    local dir="${1:-$DEFAULT_DIR}" f="${2:?用法: restore [DIR] <.sql|.sql.gz|rsync://user@host[:port]/path/file|alist:///path/file>}"
    _svc_exists "$dir" "db" || error "MariaDB 未部署"
    load_env "$dir"

    # ── 支持 rsync:// URI：先拉取到临时目录再恢复 ───────────
    local _tmp_dir="" _cleanup=0
    if [[ "$f" == rsync://* ]]; then
        _check_rsync
        _parse_rsync_uri "$f"   # 设置 RSYNC_URI_{USER,HOST,PORT,PATH}
        _tmp_dir=$(mktemp -d)
        _cleanup=1
        local _fname; _fname=$(basename "$RSYNC_URI_PATH")
        local _key_opt=()
        [[ -n "${RSYNC_KEY:-}" ]] && _key_opt=(-i "$RSYNC_KEY")
        local _ssh_cmd="ssh -p ${RSYNC_URI_PORT} -o StrictHostKeyChecking=no -o BatchMode=yes"
        [[ ${#_key_opt[@]} -gt 0 ]] && _ssh_cmd+=" -i ${RSYNC_KEY}"
        info "从远端拉取: ${RSYNC_URI_USER}@${RSYNC_URI_HOST}:${RSYNC_URI_PATH}"
        rsync -avz --progress \
            -e "$_ssh_cmd" \
            "${RSYNC_URI_USER}@${RSYNC_URI_HOST}:${RSYNC_URI_PATH}" \
            "${_tmp_dir}/" \
            || { rm -rf "$_tmp_dir"; error "rsync 拉取失败，请检查远端路径和 SSH 配置"; }
        f="${_tmp_dir}/${_fname}"
        log "已拉取到临时目录: ${f}"

    # ── 支持 alist:///path URI：通过 AList 下载到临时目录 ────
    elif [[ "$f" == alist://* ]]; then
        # alist:///path/to/file.sql.gz  →  /path/to/file.sql.gz
        local _alist_path="${f#alist://}"
        # 允许 alist:///path 和 alist://path 两种写法
        [[ "$_alist_path" == //* ]] && _alist_path="${_alist_path#/}"
        info "从 AList 网盘获取文件: ${_alist_path}"
        local _fetched; _fetched=$(_alist_fetch_file "$dir" "$_alist_path")
        _tmp_dir=$(dirname "$_fetched")
        _cleanup=1
        f="$_fetched"
        log "已从 AList 下载到临时目录: ${f}"
    fi

    [[ -f "$f" ]] || { [[ $_cleanup -eq 1 ]] && rm -rf "$_tmp_dir"; error "文件不存在: ${f}"; }
    [[ "$f" == *.gz ]] && { gzip -t "$f" || { [[ $_cleanup -eq 1 ]] && rm -rf "$_tmp_dir"; error "gz 文件损坏: ${f}"; }; }

    local base; base=$(basename "$f")
    local db="${base%.sql.gz}"; db="${db%.sql}"
    db="${db%_[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]_[0-9][0-9][0-9][0-9][0-9][0-9]}"
    if ! [[ "$db" =~ ^[A-Za-z0-9_]{1,64}$ ]]; then
        warn "无法从文件名推断库名（得到: '${db}'）"
        read -rp "  请手动输入目标库名: " db
        _check_id "$db" "数据库名"
    else
        warn "将从文件名推断目标库为: ${db}（如不正确请 Ctrl+C 后手动指定）"
    fi
    warn "将恢复到库: ${db}"; read -rp "确认? [y/N] " c
    if [[ "${c,,}" != "y" ]]; then
        info "已取消"
        [[ $_cleanup -eq 1 ]] && rm -rf "$_tmp_dir"
        return
    fi
    db_exec "$dir" -e "CREATE DATABASE IF NOT EXISTS \`${db}\`
        CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;"
    if [[ "$f" == *.gz ]]; then
        gzip -dc "$f" | compose_run "$dir" exec -T \
            -e MYSQL_PWD="${MARIADB_ROOT_PASSWORD}" db mariadb -uroot "${db}"
    else
        compose_run "$dir" exec -T \
            -e MYSQL_PWD="${MARIADB_ROOT_PASSWORD}" db mariadb -uroot "${db}" < "$f"
    fi
    [[ $_cleanup -eq 1 ]] && rm -rf "$_tmp_dir"
    log "恢复完成: ${db}"
}

# ════════════════════════════════════════════════════════════
# 运维命令
# ════════════════════════════════════════════════════════════
cmd_status() {
    local dir="${1:-$DEFAULT_DIR}"; load_env "$dir"
    header "服务状态"; compose_run "$dir" ps
    if _svc_exists "$dir" "db"; then
        header "MariaDB"
        if compose_run "$dir" exec -T -e MYSQL_PWD="${MARIADB_ROOT_PASSWORD}" \
                db mariadb-admin -h 127.0.0.1 --skip-ssl -uroot ping --silent 2>/dev/null; then
            log "✓ 响应正常"
            db_exec "$dir" -e "SHOW STATUS LIKE 'Threads_connected';"
        else warn "✗ 无响应"; fi
    fi
    if _svc_exists "$dir" "redis"; then
        header "Redis"
        if compose_run "$dir" exec -T redis \
                redis-cli -h 127.0.0.1 -a "${REDIS_PASSWORD}" ping 2>/dev/null | grep -q PONG; then
            log "✓ 响应正常"
            compose_run "$dir" exec -T redis redis-cli -h 127.0.0.1 -a "${REDIS_PASSWORD}" \
                info server 2>/dev/null | grep -E "redis_version|used_memory_human|connected_clients"
        else warn "✗ 无响应"; fi
    fi
}

# start / stop 共用：op=start|stop  DIR  [SVC]
_svc_op() {
    local op="$1" dir="${2:-$DEFAULT_DIR}" svc="${3:-}"
    if [[ -n "$svc" ]]; then
        _svc_exists "$dir" "$svc" || error "服务 ${svc} 未部署"
        compose_run "$dir" "$op" "$svc"
    else
        compose_run "$dir" "$op"
    fi
}
cmd_start() { _svc_op start "$@"; }
cmd_stop()  { _svc_op stop  "$@"; }

cmd_logs() {
    local dir="${1:-$DEFAULT_DIR}" svc="${2:?用法: logs [DIR] <db|redis>}"
    _svc_exists "$dir" "$svc" || error "服务 ${svc} 未部署"
    compose_run "$dir" logs -f --tail=100 "$svc"
}

# ════════════════════════════════════════════════════════════
# 交互菜单
# ════════════════════════════════════════════════════════════
_pause() { echo; read -rp "  按 Enter 返回..." _ || true; }
_ask()   {   # PROMPT VAR [DEFAULT]
    local hint=""; [[ -n "${3:-}" ]] && hint=" [${3}]"
    read -rp "  ${1}${hint}: " "$2"
    if [[ -z "${!2}" && -n "${3:-}" ]]; then
        printf -v "$2" '%s' "$3"
    fi
    return 0
}

_mhdr() {
    clear; echo
    _c "1;34" "╔══════════════════════════════════════════════╗"
    _c "1;34" "║   infra-shared.sh  MariaDB + Redis 管理      ║"
    _c "1;34" "╚══════════════════════════════════════════════╝"
    echo
}

_deployed_svcs() {   # DIR → 打印已部署服务
    local out=""
    _svc_exists "$1" "db"    && out+=" MariaDB"
    _svc_exists "$1" "redis" && out+=" Redis"
    [[ -n "$out" ]] && info "已部署:${out}" || warn "尚未部署任何服务"
    echo
}

# 公共：收集部署参数（DIR WG_IP），失败 return 1
_ask_deploy_params() {
    local auto_ip=""
    ip link show "${WG_IFACE}" &>/dev/null \
        && auto_ip=$(ip addr show "${WG_IFACE}" | awk '/inet /{gsub(/\/.*/, "", $2); print $2; exit}') \
        || warn "${WG_IFACE} 未检测到"
    _ask "部署目录" DIR "$DEFAULT_DIR"
    _ask "WireGuard IP" WG_IP "$auto_ip"
    [[ -n "$WG_IP" ]] || { warn "WireGuard IP 不能为空"; return 1; }
    [[ "$WG_IP" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || { warn "IP 格式无效"; return 1; }
}

menu_main() {
    while true; do
        _mhdr
        echo "  ─── 部署 ────────────────────────────────────"
        echo "  1) 部署服务（MariaDB / Redis / 全部）"
        echo "  2) 更新服务镜像"
        echo "  ─── 运维 ────────────────────────────────────"
        echo "  3) 查看状态    4) 启动    5) 停止    6) 日志"
        echo "  ─── 数据 ────────────────────────────────────"
        echo "  7) 数据库管理 ▶        8) 备份 / 恢复 ▶"
        echo "  ─── 调优 ────────────────────────────────────"
        echo "  9) 性能调优 ▶（buffer_pool / maxmemory 等）"
        echo "  ─────────────────────────────────────────────"
        echo "  0) 退出"
        echo
        read -rp "  请选择 [0-9]: " CH
        case "$CH" in
            1) menu_deploy  ;; 2) menu_update ;;
            3) menu_status  ;; 4) menu_svc start ;;
            5) menu_svc stop ;; 6) menu_logs ;;
            7) menu_db      ;; 8) menu_bk ;;
            9) menu_tune    ;;
            0) info "再见！"; exit 0 ;;
            *) warn "无效选项"; sleep 1 ;;
        esac
    done
}

menu_deploy() {
    _mhdr; _c "1;33" "  ▶ 部署服务"; echo
    _ask_deploy_params || { _pause; return; }
    echo "  a) MariaDB + Redis（全部）"
    echo "  b) 仅 MariaDB"
    echo "  c) 仅 Redis"
    echo
    read -rp "  请选择 [a/b/c]: " CH
    local target
    case "$CH" in
        a) target=all   ;; b) target=db ;; c) target=redis ;;
        *) warn "无效选项"; _pause; return ;;
    esac
    warn "将部署 ${target} 到 ${DIR}（WG: ${WG_IP}）"
    read -rp "  确认? [y/N] " C; [[ "${C,,}" == "y" ]] || { info "已取消"; _pause; return; }
    echo; _menu_run cmd_deploy "$DIR" "$WG_IP" "$target" || true; _pause
}

menu_update() {
    _mhdr; _c "1;33" "  ▶ 更新服务镜像"; echo
    _ask "部署目录" DIR "$DEFAULT_DIR"; _deployed_svcs "$DIR"
    echo "  a) 全部更新  b) 仅 MariaDB  c) 仅 Redis"
    read -rp "  请选择 [a/b/c]: " CH
    local target
    case "$CH" in
        a) target=all   ;; b) target=db ;; c) target=redis ;;
        *) warn "无效选项"; _pause; return ;;
    esac
    warn "将拉取最新镜像并重建 ${target}"
    read -rp "  确认? [y/N] " C; [[ "${C,,}" == "y" ]] || { info "已取消"; _pause; return; }
    echo; _menu_run cmd_update "$DIR" "$target" || true; _pause
}

menu_status() {
    _mhdr; _ask "部署目录" DIR "$DEFAULT_DIR"; echo
    _menu_run cmd_status "$DIR" || true; _pause
}

# 通用 start/stop 菜单，op=start|stop
menu_svc() {
    local op="$1" label; [[ "$op" == "start" ]] && label="启动" || label="停止"
    _mhdr; _c "1;33" "  ▶ ${label}服务"; echo
    _ask "部署目录" DIR "$DEFAULT_DIR"; _deployed_svcs "$DIR"
    echo "  1) 全部  2) MariaDB  3) Redis"
    read -rp "  请选择 [1-3]: " CH
    local svc=""
    case "$CH" in 1) ;; 2) svc="db" ;; 3) svc="redis" ;;
        *) warn "无效选项"; _pause; return ;;
    esac
    read -rp "  确认${label}? [y/N] " C; [[ "${C,,}" == "y" ]] || { info "已取消"; _pause; return; }
    if [[ "$op" == "start" ]]; then
        _menu_run cmd_start "$DIR" ${svc:+"$svc"} || true
    else
        _menu_run cmd_stop  "$DIR" ${svc:+"$svc"} || true
    fi
    _pause
}

menu_logs() {
    _mhdr; _c "1;33" "  ▶ 查看日志"; echo
    _ask "部署目录" DIR "$DEFAULT_DIR"; _deployed_svcs "$DIR"
    echo "  1) MariaDB  2) Redis"
    read -rp "  请选择 [1-2]: " CH
    local svc; case "$CH" in 1) svc=db ;; 2) svc=redis ;; *) warn "无效"; _pause; return ;; esac
    info "Ctrl+C 退出"
    local _ot; _ot=$(trap -p INT); trap 'true' INT
    cmd_logs "$DIR" "$svc" || true
    [[ -n "$_ot" ]] && eval "$_ot" || trap - INT
    _pause
}

menu_db() {
    while true; do
        _mhdr; _c "1;33" "  ▶ 数据库管理"; echo
        echo "  1) 新建库和用户  2) 删除库和用户  3) 清空库内容"
        echo "  4) 列出库/用户   5) 修改用户密码  0) 返回"
        echo
        read -rp "  请选择 [0-5]: " CH
        case "$CH" in
            1) menu_db_add    ;; 2) menu_db_del   ;; 3) menu_db_clear ;;
            4) menu_db_list   ;; 5) menu_db_passwd ;; 0) return ;;
            *) warn "无效选项"; sleep 1 ;;
        esac
    done
}

_db_menu_head() {   # TITLE
    _mhdr; _c "1;33" "  ▶ $1"; echo
    _ask "部署目录" DIR "$DEFAULT_DIR"
}

menu_db_add() {
    _db_menu_head "新建数据库和用户"
    _ask "数据库名" DB_NAME ""; [[ -n "$DB_NAME" ]] || { warn "不能为空"; _pause; return; }
    _ask "用户名"   DB_USER ""; [[ -n "$DB_USER" ]] || { warn "不能为空"; _pause; return; }
    _ask "密码（留空自动生成）" DB_PW "$(randpw)"; echo
    _menu_run cmd_add_db "$DIR" "$DB_NAME" "$DB_USER" "$DB_PW" || true; _pause
}

menu_db_del() {
    _db_menu_head "删除数据库和用户"
    _menu_run cmd_list_db "$DIR" 2>/dev/null || true; echo
    _ask "数据库名" DB_NAME ""; _ask "用户名" DB_USER ""
    [[ -n "$DB_NAME" && -n "$DB_USER" ]] || { warn "不能为空"; _pause; return; }
    echo; _menu_run cmd_del_db "$DIR" "$DB_NAME" "$DB_USER" || true; _pause
}

menu_db_clear() {
    _db_menu_head "清空数据库内容（保留库和权限）"
    _menu_run cmd_list_db "$DIR" 2>/dev/null || true; echo
    _ask "数据库名" DB_NAME ""; [[ -n "$DB_NAME" ]] || { warn "不能为空"; _pause; return; }
    echo; _menu_run cmd_clear_db "$DIR" "$DB_NAME" || true; _pause
}

menu_db_list() {
    _db_menu_head "数据库 / 用户列表"; echo
    _menu_run cmd_list_db "$DIR" || true; _pause
}

menu_db_passwd() {
    _db_menu_head "修改用户密码"
    _ask "用户名" DB_USER ""; [[ -n "$DB_USER" ]] || { warn "不能为空"; _pause; return; }
    _ask "新密码（留空自动生成）" NEW_PW "$(randpw)"; echo
    _menu_run cmd_passwd "$DIR" "$DB_USER" "$NEW_PW" || true; _pause
}

menu_bk() {
    while true; do
        _mhdr; _c "1;33" "  ▶ 备份 / 恢复"; echo
        echo "  ─── 本地 ────────────────────────────────────"
        echo "  1) 备份所有数据库（本地）"
        echo "  2) 恢复单库（本地文件）"
        echo "  ─── 远端 rsync ──────────────────────────────"
        echo "  3) 备份并推送到 rsync 远端"
        echo "  4) 推送现有备份到 rsync 远端"
        echo "  5) 从 rsync 远端拉取备份文件"
        echo "  6) 从 rsync 远端文件直接恢复"
        echo "  7) 配置 / 测试 rsync 远端"
        echo "  ─── AList 网盘 ──────────────────────────────"
        echo "  8) 备份并上传到 AList 网盘"
        echo "  9) 上传现有备份到 AList 网盘"
        echo "  a) 从 AList 网盘下载备份"
        echo "  b) 从 AList 网盘直接恢复"
        echo "  c) 列出 AList 网盘备份文件"
        echo "  d) 配置 / 测试 AList 连接"
        echo "  ─────────────────────────────────────────────"
        echo "  0) 返回"
        echo
        read -rp "  请选择 [0-9/a-d]: " CH
        case "$CH" in
            1) menu_bk_backup         ;;
            2) menu_bk_restore        ;;
            3) menu_bk_backup_rsync   ;;
            4) menu_bk_push           ;;
            5) menu_bk_pull           ;;
            6) menu_bk_restore_remote ;;
            7) menu_bk_rsync_config   ;;
            8) menu_bk_backup_alist   ;;
            9) menu_bk_alist_push     ;;
            a|A) menu_bk_alist_pull   ;;
            b|B) menu_bk_alist_restore;;
            c|C) menu_bk_alist_list   ;;
            d|D) menu_bk_alist_config ;;
            0) return ;;
            *) warn "无效选项"; sleep 1 ;;
        esac
    done
}

menu_bk_backup() {
    _db_menu_head "备份所有数据库（本地）"
    _ask "输出目录" DEST "${DIR}/backup"; echo
    _menu_run cmd_backup "$DIR" "$DEST" || true; _pause
}

menu_bk_restore() {
    _db_menu_head "恢复数据库（本地文件）"
    _ask "SQL 文件（.sql 或 .sql.gz）" SQL_FILE ""
    [[ -n "$SQL_FILE" ]] || { warn "不能为空"; _pause; return; }
    echo; _menu_run cmd_restore "$DIR" "$SQL_FILE" || true; _pause
}

menu_bk_backup_rsync() {
    _db_menu_head "备份所有数据库并推送到远端"
    _ask "本地输出目录" DEST "${DIR}/backup"; echo
    _menu_run cmd_backup "$DIR" "$DEST" "--rsync" || true; _pause
}

menu_bk_push() {
    _db_menu_head "推送现有备份目录到远端"
    _ask "本地备份目录" LOCAL_DIR "${DIR}/backup"; echo
    _menu_run cmd_rsync_push "$DIR" "$LOCAL_DIR" || true; _pause
}

menu_bk_pull() {
    _db_menu_head "从远端拉取备份文件到本地"
    _ask "本地存放目录" LOCAL_DEST "${DIR}/backup/remote"; echo
    _menu_run cmd_rsync_pull "$DIR" "$LOCAL_DEST" || true; _pause
}

menu_bk_restore_remote() {
    _db_menu_head "从远端文件直接恢复"
    # 先列出远端文件供参考
    info "正在列出远端备份目录..."
    load_env "$DIR" 2>/dev/null || true
    (
        _load_rsync_conf "$DIR" 2>/dev/null \
        && _rsync_list "$DIR" 2>/dev/null
    ) || warn "无法列出远端文件（请确认 rsync 已配置）"
    echo
    _ask "远端文件路径（rsync://user@host[:port]/path/file.sql.gz）" REMOTE_FILE ""
    [[ -n "$REMOTE_FILE" ]] || { warn "不能为空"; _pause; return; }
    echo; _menu_run cmd_restore "$DIR" "$REMOTE_FILE" || true; _pause
}

menu_bk_rsync_config() {
    _db_menu_head "配置 rsync 远端"
    _menu_run cmd_rsync_config "$DIR" || true; _pause
}

# ── AList 菜单函数 ────────────────────────────────────────────
menu_bk_backup_alist() {
    _db_menu_head "备份所有数据库并上传到 AList 网盘"
    _ask "本地临时目录" DEST "${DIR}/backup"; echo
    _menu_run cmd_backup "$DIR" "$DEST" "--alist" || true; _pause
}

menu_bk_alist_push() {
    _db_menu_head "上传现有备份目录到 AList 网盘"
    _ask "本地备份目录" LOCAL_DIR "${DIR}/backup"; echo
    _menu_run cmd_alist_push "$DIR" "$LOCAL_DIR" || true; _pause
}

menu_bk_alist_pull() {
    _db_menu_head "从 AList 网盘下载备份文件到本地"
    _ask "本地存放目录" LOCAL_DEST "${DIR}/backup/alist"; echo
    _menu_run cmd_alist_pull "$DIR" "$LOCAL_DEST" || true; _pause
}

menu_bk_alist_restore() {
    _db_menu_head "从 AList 网盘直接恢复数据库"
    # 先列出网盘上的文件供参考
    info "正在列出 AList 网盘备份目录..."
    load_env "$DIR" 2>/dev/null || true
    ( _alist_list "$DIR" 2>/dev/null ) || warn "无法列出 AList 文件（请先完成 alist-config）"
    echo
    echo "  输入格式: alist:///AList内部路径/文件名.sql.gz"
    echo "  示例:     alist:///onedrive/backup/infra/mydb_20250101_120000.sql.gz"
    _ask "AList 文件路径（alist:///...）" ALIST_FILE ""
    [[ -n "$ALIST_FILE" ]] || { warn "不能为空"; _pause; return; }
    echo; _menu_run cmd_restore "$DIR" "$ALIST_FILE" || true; _pause
}

menu_bk_alist_list() {
    _db_menu_head "列出 AList 网盘备份文件"
    _ask "AList 内部路径（留空用默认）" ALIST_PATH ""; echo
    _menu_run cmd_alist_list "$DIR" ${ALIST_PATH:+"$ALIST_PATH"} || true; _pause
}

menu_bk_alist_config() {
    _db_menu_head "配置 AList 连接"
    _menu_run cmd_alist_config "$DIR" || true; _pause
}

# ── 调优菜单 ──────────────────────────────────────────────────
menu_tune() {
    while true; do
        _mhdr; _c "1;33" "  ▶ 性能调优"; echo
        echo "  1) MariaDB 参数（buffer_pool / log / connections）"
        echo "  2) Redis 参数（maxmemory）"
        echo "  0) 返回"
        echo
        read -rp "  请选择 [0-2]: " CH
        case "$CH" in
            1) menu_tune_db    ;;
            2) menu_tune_redis ;;
            0) return ;;
            *) warn "无效选项"; sleep 1 ;;
        esac
    done
}

menu_tune_db() {
    _db_menu_head "MariaDB 性能调优"
    _menu_run cmd_tune_db "$DIR" || true; _pause
}

menu_tune_redis() {
    _db_menu_head "Redis 性能调优"
    _menu_run cmd_tune_redis "$DIR" || true; _pause
}

# ════════════════════════════════════════════════════════════
# 入口
# ════════════════════════════════════════════════════════════
main() {
    _check_deps
    [[ $# -eq 0 ]] && { menu_main; return; }
    local cmd="$1"; shift
    case "$cmd" in
        deploy)    cmd_deploy   "$@" ;;
        update)    cmd_update   "$@" ;;
        add-db)    cmd_add_db   "$@" ;;
        del-db)    cmd_del_db   "$@" ;;
        clear-db)  cmd_clear_db "$@" ;;
        list-db)   cmd_list_db  "$@" ;;
        passwd)    cmd_passwd   "$@" ;;
        backup)       cmd_backup       "$@" ;;
        restore)      cmd_restore      "$@" ;;
        tune-db)      cmd_tune_db      "$@" ;;
        tune-redis)   cmd_tune_redis   "$@" ;;
        rsync-push)   cmd_rsync_push   "$@" ;;
        rsync-pull)   cmd_rsync_pull   "$@" ;;
        rsync-config) cmd_rsync_config "$@" ;;
        alist-push)   cmd_alist_push   "$@" ;;
        alist-pull)   cmd_alist_pull   "$@" ;;
        alist-list)   cmd_alist_list   "$@" ;;
        alist-config) cmd_alist_config "$@" ;;
        status)    cmd_status   "$@" ;;
        start)     cmd_start    "$@" ;;
        stop)      cmd_stop     "$@" ;;
        logs)      cmd_logs     "$@" ;;
        help|--help|-h)
            sed -n '/^# 用法/,/^# ══/p' "$0" | sed 's/^# \{0,2\}//' | head -n -1 ;;
        *) error "未知子命令: ${cmd}，执行 help 查看用法" ;;
    esac
}

main "$@"