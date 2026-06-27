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
#   ./infra-shared.sh restore [DIR] <SQL文件|rsync://user@host[:port]/远端路径/文件>
#   ./infra-shared.sh rsync-push   [DIR] [LOCAL_DIR]   # 推送备份到远端
#   ./infra-shared.sh rsync-pull   [DIR] [LOCAL_DEST]  # 拉取远端备份到本地
#   ./infra-shared.sh rsync-config [DIR]               # 配置/查看远端 rsync 参数
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
    local _ALLOWED_KEYS='WG_IP|MARIADB_ROOT_PASSWORD|MARIADB_DATABASE|MARIADB_USER|MARIADB_PASSWORD|REDIS_PASSWORD|DEPLOY_DB|DEPLOY_REDIS|RSYNC_REMOTE|RSYNC_USER|RSYNC_PORT|RSYNC_KEY|RSYNC_REMOTE_DIR'
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
    export MYSQL_PWD="${MARIADB_ROOT_PASSWORD}"
    compose_run "$d" exec -T -e MYSQL_PWD db mariadb -uroot "$@"
}

db_sql() {   # DIR SQL
    export MYSQL_PWD="${MARIADB_ROOT_PASSWORD}"
    compose_run "$1" exec -T -e MYSQL_PWD \
        db mariadb -uroot < <(printf '%s\n' "$2")
}

db_sql_on() {   # DIR DB SQL  — 直接指定目标库
    export MYSQL_PWD="${MARIADB_ROOT_PASSWORD}"
    compose_run "$1" exec -T -e MYSQL_PWD \
        db mariadb -uroot "$2" < <(printf '%s\n' "$3")
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
    # 调用方须在调用前完成 load_env，此处不重复 load
    local dir="$1"
    mkdir -p "$dir/redis-conf"
    cat > "$dir/redis-conf/redis.conf" <<CONF
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
# rsync 工具函数
# ════════════════════════════════════════════════════════════

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
# 备份 / 恢复
# ════════════════════════════════════════════════════════════
# cmd_backup [DIR] [DEST] [--rsync]
#   --rsync : 备份完成后自动推送到远端（须已配置 rsync-config）

cmd_backup() {
    umask 077 # 安全修复：强制新建目录与文件权限为 700/600
    local dir="${1:-$DEFAULT_DIR}" dest="${2:-${1:-$DEFAULT_DIR}/backup}" do_rsync=0
    for _a in "$@"; do [[ "$_a" == "--rsync" ]] && do_rsync=1; done

    _svc_exists "$dir" "db" || error "MariaDB 未部署"
    load_env "$dir"
    
    mkdir -p "$dest"
    chmod 700 "$dest" # 安全修复：收紧已有目录权限
    
    local ts; ts=$(date +%Y%m%d_%H%M%S)
    header "备份 → ${dest}"
    local dbs failed=0
    dbs=$(db_exec "$dir" -sN -e \
        "SELECT schema_name FROM information_schema.schemata
         WHERE schema_name NOT IN ('mysql','information_schema','performance_schema','sys');")
         
    export MYSQL_PWD="${MARIADB_ROOT_PASSWORD}"
    
    while IFS= read -r db; do
        [[ -n "$db" ]] || continue
        local out="${dest}/${db}_${ts}.sql.gz" tmp="${dest}/${db}_${ts}.sql.gz.tmp"
        info "备份 ${db}..."
        if compose_run "$dir" exec -T -e MYSQL_PWD \
                db mariadb-dump -uroot --single-transaction --routines --triggers "${db}" \
            | gzip > "$tmp"; then
            mv "$tmp" "$out"
            log "✓ ${db} ($(du -sh "$out" | cut -f1))"
        else
            rm -f "$tmp"; warn "✗ ${db} 失败"; (( failed++ )) || true
        fi
    done <<< "$dbs"
    (( failed == 0 )) && log "备份完成: ${dest}" || { warn "${failed} 个库失败"; return 1; }

    if (( do_rsync )); then
        header "推送备份到远端"
        _rsync_push "$dir" "${dest%/}/" ""
    fi
}

cmd_restore() {
    umask 077 # 安全修复：保障恢复过程中临时目录的安全
    local dir="${1:-$DEFAULT_DIR}" f="${2:?用法: restore [DIR] <.sql|.sql.gz|rsync://user@host[:port]/path/file>}"
    _svc_exists "$dir" "db" || error "MariaDB 未部署"
    load_env "$dir"

    local _tmp_dir="" _cleanup=0
    if [[ "$f" == rsync://* ]]; then
        _check_rsync
        _parse_rsync_uri "$f"
        _tmp_dir=$(mktemp -d)
        chmod 700 "$_tmp_dir"
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
        
    export MYSQL_PWD="${MARIADB_ROOT_PASSWORD}"
    
    if [[ "$f" == *.gz ]]; then
        gzip -dc "$f" | compose_run "$dir" exec -T \
            -e MYSQL_PWD db mariadb -uroot "${db}"
    else
        compose_run "$dir" exec -T \
            -e MYSQL_PWD db mariadb -uroot "${db}" < "$f"
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
        export MYSQL_PWD="${MARIADB_ROOT_PASSWORD}"
        if compose_run "$dir" exec -T -e MYSQL_PWD \
                db mariadb-admin -h 127.0.0.1 --skip-ssl -uroot ping --silent 2>/dev/null; then
            log "✓ 响应正常"
            db_exec "$dir" -e "SHOW STATUS LIKE 'Threads_connected';"
        else warn "✗ 无响应"; fi
    fi
    
    if _svc_exists "$dir" "redis"; then
        header "Redis"
        export REDISCLI_AUTH="${REDIS_PASSWORD}"
        if compose_run "$dir" exec -T -e REDISCLI_AUTH redis \
                redis-cli -h 127.0.0.1 ping 2>/dev/null | grep -q PONG; then
            log "✓ 响应正常"
            compose_run "$dir" exec -T -e REDISCLI_AUTH redis redis-cli -h 127.0.0.1 \
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
        echo "  3) 备份并推送到远端"
        echo "  4) 推送现有备份到远端"
        echo "  5) 从远端拉取备份文件"
        echo "  6) 从远端文件直接恢复"
        echo "  7) 配置 / 测试 rsync 远端"
        echo "  ─────────────────────────────────────────────"
        echo "  0) 返回"
        echo
        read -rp "  请选择 [0-7]: " CH
        case "$CH" in
            1) menu_bk_backup        ;;
            2) menu_bk_restore       ;;
            3) menu_bk_backup_rsync  ;;
            4) menu_bk_push          ;;
            5) menu_bk_pull          ;;
            6) menu_bk_restore_remote;;
            7) menu_bk_rsync_config  ;;
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
        rsync-push)   cmd_rsync_push   "$@" ;;
        rsync-pull)   cmd_rsync_pull   "$@" ;;
        rsync-config) cmd_rsync_config "$@" ;;
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
