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
#   ./infra-shared.sh backup  [DIR] [DEST]
#   ./infra-shared.sh restore [DIR] <SQL文件>
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
    [[ ${#1} -ge 8 ]]  || error "$2 至少 8 个字符"
}

load_env() {
    [[ -f "$1/.env" ]] || error ".env 不存在: $1/.env"
    chmod 600 "$1/.env" 2>/dev/null || true
    # shellcheck disable=SC1090
    source "$1/.env" </dev/null
}

_env_set() {   # DIR KEY VAL
    if grep -q "^$2=" "$1/.env" 2>/dev/null; then
        sed -i "s|^$2=.*|$2=$3|" "$1/.env"
    else
        echo "$2=$3" >> "$1/.env"
    fi
}

_svc_exists() {   # DIR SVC
    grep -q "^  $2:" "$1/docker-compose.yml" 2>/dev/null
}

_docker_subnet() {
    local s
    s=$(docker network inspect bridge \
        --format '{{range .IPAM.Config}}{{.Subnet}}{{end}}' 2>/dev/null || true)
    [[ "$s" =~ ^([0-9]+\.[0-9]+)\. ]] && echo "${BASH_REMATCH[1]}.%" || echo "172.17.%"
}

# ── 依赖检查 ─────────────────────────────────────────────────
_check_deps() {
    local missing=()
    for cmd in docker ip awk grep; do
        command -v "$cmd" >/dev/null 2>&1 || missing+=("$cmd")
    done

    # 明确检查 docker compose 插件（V2）
    if ! docker compose version >/dev/null 2>&1; then
        missing+=("docker compose (插件)")
    fi

    if [[ ${#missing[@]} -gt 0 ]]; then
        error "缺少依赖命令: ${missing[*]}。请安装并确保在 PATH 中"
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

# ════════════════════════════════════════════════════════════
# 配置文件生成
# ════════════════════════════════════════════════════════════
_write_mariadb_conf() {
    mkdir -p "$1/mariadb-conf"
    cat > "$1/mariadb-conf/custom.cnf" <<'INI'
[mysqld]
innodb_buffer_pool_size        = 512M
innodb_log_file_size           = 128M
innodb_flush_log_at_trx_commit = 2
max_connections                = 200
query_cache_type               = 0
character-set-server           = utf8mb4
collation-server               = utf8mb4_unicode_ci
bind-address                   = 0.0.0.0
slow_query_log                 = 1
slow_query_log_file            = /var/lib/mysql/slow.log
long_query_time                = 2
INI
}

_write_redis_conf() {
    load_env "$1"
    mkdir -p "$1/redis-conf"
    cat > "$1/redis-conf/redis.conf" <<CONF
bind 0.0.0.0
port ${REDIS_PORT}
requirepass ${REDIS_PASSWORD}
save 900 1
save 300 10
save 60 10000
appendonly yes
appendfsync everysec
maxmemory 512mb
maxmemory-policy allkeys-lru
loglevel notice
logfile ""
CONF
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
            printf "MARIADB_ROOT_PASSWORD=%s\nMARIADB_DATABASE=wordpress\nMARIADB_USER=wpuser\nMARIADB_PASSWORD=%s\n" \
                "$(randpw)" "$(randpw)" >> "$dir/.env"
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
            echo "REDIS_PASSWORD=$(randpw)" >> "$dir/.env"
            log "Redis 凭据已生成"
        else
            warn "Redis 凭据已存在，跳过生成"
        fi
        _env_set "$dir" "DEPLOY_REDIS" "1"
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
    log "库: ${db}  用户: ${user}  密码: ${pw}  主机: ${WG_IP}:${MARIADB_PORT}"
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
    local sql
    sql=$(db_exec "$dir" -sN -e \
        "SELECT CONCAT('DROP TABLE IF EXISTS \`',table_name,'\`;')
         FROM information_schema.tables WHERE table_schema='${db}';")
    [[ -n "$sql" ]] || { info "库 ${db} 无表，无需清空"; return; }
    db_sql "$dir" "USE \`${db}\`; SET FOREIGN_KEY_CHECKS=0; ${sql} SET FOREIGN_KEY_CHECKS=1;"
    log "已清空库 ${db}（$(echo "$sql" | wc -l) 张表）"
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
# 备份 / 恢复
# ════════════════════════════════════════════════════════════
cmd_backup() {
    local dir="${1:-$DEFAULT_DIR}" dest="${2:-${1:-$DEFAULT_DIR}/backup}"
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
            rm -f "$tmp"; warn "✗ ${db} 失败"; (( failed++ ))
        fi
    done <<< "$dbs"
    (( failed == 0 )) && log "备份完成: ${dest}" || { warn "${failed} 个库失败"; return 1; }
}

cmd_restore() {
    local dir="${1:-$DEFAULT_DIR}" f="${2:?用法: restore [DIR] <.sql|.sql.gz>}"
    _svc_exists "$dir" "db" || error "MariaDB 未部署"
    load_env "$dir"; [[ -f "$f" ]] || error "文件不存在: ${f}"
    [[ "$f" == *.gz ]] && { gzip -t "$f" || error "gz 文件损坏: ${f}"; }
    local base; base=$(basename "$f")
    local db="${base%.sql.gz}"; db="${db%.sql}"
    db="${db%_[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]_[0-9][0-9][0-9][0-9][0-9][0-9]}"
    if ! [[ "$db" =~ ^[A-Za-z0-9_]{1,64}$ ]]; then
        warn "无法从文件名推断库名（得到: '${db}'）"
        read -rp "  请手动输入目标库名: " db
        _check_id "$db" "数据库名"
    fi
    warn "将恢复到库: ${db}"; read -rp "确认? [y/N] " c
    [[ "${c,,}" == "y" ]] || { info "已取消"; return; }
    db_exec "$dir" -e "CREATE DATABASE IF NOT EXISTS \`${db}\`
        CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;"
    if [[ "$f" == *.gz ]]; then
        gzip -dc "$f" | compose_run "$dir" exec -T \
            -e MYSQL_PWD="${MARIADB_ROOT_PASSWORD}" db mariadb -uroot "${db}"
    else
        compose_run "$dir" exec -T \
            -e MYSQL_PWD="${MARIADB_ROOT_PASSWORD}" db mariadb -uroot "${db}" < "$f"
    fi
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
_pause() { echo; read -rp "  按 Enter 返回..." _; }
_ask()   {   # PROMPT VAR [DEFAULT]
    local hint=""; [[ -n "${3:-}" ]] && hint=" [${3}]"
    read -rp "  ${1}${hint}: " "$2"
    [[ -z "${!2}" && -n "${3:-}" ]] && printf -v "$2" '%s' "$3"
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
        echo "  ─────────────────────────────────────────────"
        echo "  0) 退出"
        echo
        read -rp "  请选择 [0-8]: " CH
        case "$CH" in
            1) menu_deploy  ;; 2) menu_update ;;
            3) menu_status  ;; 4) menu_svc start ;;
            5) menu_svc stop ;; 6) menu_logs ;;
            7) menu_db      ;; 8) menu_bk ;;
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
    echo; cmd_deploy "$DIR" "$WG_IP" "$target"; _pause
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
    echo; cmd_update "$DIR" "$target"; _pause
}

menu_status() {
    _mhdr; _ask "部署目录" DIR "$DEFAULT_DIR"; echo
    cmd_status "$DIR"; _pause
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
    cmd_${op} "$DIR" $svc; _pause
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
    cmd_add_db "$DIR" "$DB_NAME" "$DB_USER" "$DB_PW"; _pause
}

menu_db_del() {
    _db_menu_head "删除数据库和用户"
    cmd_list_db "$DIR" 2>/dev/null || true; echo
    _ask "数据库名" DB_NAME ""; _ask "用户名" DB_USER ""
    [[ -n "$DB_NAME" && -n "$DB_USER" ]] || { warn "不能为空"; _pause; return; }
    echo; cmd_del_db "$DIR" "$DB_NAME" "$DB_USER"; _pause
}

menu_db_clear() {
    _db_menu_head "清空数据库内容（保留库和权限）"
    cmd_list_db "$DIR" 2>/dev/null || true; echo
    _ask "数据库名" DB_NAME ""; [[ -n "$DB_NAME" ]] || { warn "不能为空"; _pause; return; }
    echo; cmd_clear_db "$DIR" "$DB_NAME"; _pause
}

menu_db_list() {
    _db_menu_head "数据库 / 用户列表"; echo
    cmd_list_db "$DIR"; _pause
}

menu_db_passwd() {
    _db_menu_head "修改用户密码"
    _ask "用户名" DB_USER ""; [[ -n "$DB_USER" ]] || { warn "不能为空"; _pause; return; }
    _ask "新密码（留空自动生成）" NEW_PW "$(randpw)"; echo
    cmd_passwd "$DIR" "$DB_USER" "$NEW_PW"; _pause
}

menu_bk() {
    while true; do
        _mhdr; _c "1;33" "  ▶ 备份 / 恢复"; echo
        echo "  1) 备份所有数据库  2) 恢复单库  0) 返回"
        read -rp "  请选择 [0-2]: " CH
        case "$CH" in 1) menu_bk_backup ;; 2) menu_bk_restore ;; 0) return ;; *) warn "无效"; sleep 1 ;; esac
    done
}

menu_bk_backup() {
    _db_menu_head "备份所有数据库"
    _ask "输出目录" DEST "${DIR}/backup"; echo
    cmd_backup "$DIR" "$DEST"; _pause
}

menu_bk_restore() {
    _db_menu_head "恢复数据库"
    _ask "SQL 文件（.sql 或 .sql.gz）" SQL_FILE ""
    [[ -n "$SQL_FILE" ]] || { warn "不能为空"; _pause; return; }
    echo; cmd_restore "$DIR" "$SQL_FILE"; _pause
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
        backup)    cmd_backup   "$@" ;;
        restore)   cmd_restore  "$@" ;;
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
