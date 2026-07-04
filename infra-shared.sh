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
#   ./infra-shared.sh backup  [DIR] [DEST] [--rsync] [--alist] [--encrypt]  # 全量备份（.env+配置+全库SQL+Redis数据 → 单个 tar.gz，--encrypt 额外加密）
#   ./infra-shared.sh restore [DIR] <备份tar.gz[.enc]|rsync://user@host[:port]/path/file|alist:///path/file> [解密密钥]  # 全量恢复（可用于机器重装后整体拉起；加密备份留空密钥会交互询问）
#   ./infra-shared.sh tune-db    [DIR]               # 查看/调整 MariaDB 性能参数
#   ./infra-shared.sh tune-redis [DIR]               # 查看/调整 Redis 性能参数
#   ./infra-shared.sh rsync-config [DIR]               # 配置/查看远端 rsync 参数（backup --rsync / restore rsync://... 会用到）
#   ./infra-shared.sh alist-config [DIR]               # 配置/测试 AList 连接（backup --alist / restore alist:///... 会用到）
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

# ── 临时目录兜底清理 ──────────────────────────────────────────
# backup/restore 会用 mktemp -d 创建承载全量数据的临时目录；正常路径下各处已有
# 显式 rm -rf，这里的 trap 只是异常中断（Ctrl-C / 意外报错）时的兜底，避免在
# /tmp 里残留可能含明文密码的临时数据。
_TMP_DIRS=()
_register_tmp() { [[ -n "$1" ]] && _TMP_DIRS+=("$1"); }
_cleanup_tmp() {
    local d
    for d in "${_TMP_DIRS[@]:-}"; do
        [[ -n "$d" && -d "$d" ]] && rm -rf "$d" 2>/dev/null
    done
}
trap _cleanup_tmp EXIT

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
    # 注意：db_sql()/_grant_wg() 等函数直接把密码拼进 SQL 字符串字面量，
    # 依赖这里禁止单引号和反斜杠来防止 SQL 注入。修改此校验前必须确认
    # 所有拼接点都已改为参数化/转义，否则会重新引入注入风险。
    [[ -n "$1" ]]      || error "$2 不能为空"
    [[ "$1" != *"'"* ]] || error "$2 不能含单引号"
    [[ "$1" != *"\\"* ]] || error "$2 不能含反斜杠"
    [[ ${#1} -ge 8 ]]  || error "$2 至少 8 个字符"
}

load_env() {
    [[ -f "$1/.env" ]] || error ".env 不存在: $1/.env"
    chmod 600 "$1/.env" 2>/dev/null || true
    # 允许加载的 key 白名单（防止 .env 被篡改污染关键环境变量）
    local _ALLOWED_KEYS='WG_IP|MARIADB_ROOT_PASSWORD|MARIADB_DATABASE|MARIADB_USER|MARIADB_PASSWORD|REDIS_PASSWORD|DEPLOY_DB|DEPLOY_REDIS|MARIADB_IMAGE|REDIS_IMAGE|BACKUP_ENC_KEY|RSYNC_REMOTE|RSYNC_USER|RSYNC_PORT|RSYNC_KEY|RSYNC_REMOTE_DIR|ALIST_MODE|ALIST_MOUNT|ALIST_URL|ALIST_TOKEN|ALIST_REMOTE_DIR|INNODB_BUFFER_POOL_SIZE|INNODB_LOG_FILE_SIZE|INNODB_FLUSH_LOG|MAX_CONNECTIONS|REDIS_MAXMEMORY'
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

_check_dir_safe() {   # DIR — 防止误传危险路径后被后续 rm -rf "$dir/xxx" 误伤
    local d="$1"
    [[ -n "$d" ]] || error "DIR 不能为空"
    case "$d" in
        /|/root|/root/|/home|/home/|/etc|/etc/|/var|/var/|/usr|/usr/)
            error "DIR 不能是系统关键路径: '${d}'，请指定专用的业务目录" ;;
    esac
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
    for cmd in docker ip awk grep tar; do
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
        # 把实际使用的镜像版本钉入 .env，确保换机 restore 时用的是同一版本，
        # 而不是恢复脚本当前默认的 MARIADB_IMAGE（版本不一致可能导致导入失败）。
        grep -q "^MARIADB_IMAGE=" "$dir/.env" 2>/dev/null || _env_set "$dir" "MARIADB_IMAGE" "$MARIADB_IMAGE"
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
        grep -q "^REDIS_IMAGE=" "$dir/.env" 2>/dev/null || _env_set "$dir" "REDIS_IMAGE" "$REDIS_IMAGE"
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

# 尽力而为：把 add-db 等方式创建、绑定在"旧 WG 网段"上的其他账号，
# 自动克隆一份到新 WG/Docker 网段。做法是用 SHOW CREATE USER / SHOW GRANTS
# 读出已经加密好的凭据和权限原样搬到新 host，不需要（也拿不到）明文密码。
# 局限：只处理 Host 恰好等于 "<旧网段>.%" 这种模式（本脚本 add-db/_grant_wg
# 固定采用的格式）；如果历史上手工建过其他 host 模式的账号，不在处理范围内。
_reauth_extra_users() {   # DIR OLD_WG_SUB NEW_WG_SUB DOCKER_SUB SKIP_USER
    local dir="$1" old_sub="$2" new_wg_sub="$3" docker_sub="$4" skip_user="${5:-}"
    [[ -n "$old_sub" && "$old_sub" != "$new_wg_sub" ]] || return 0

    local users
    users=$(db_exec "$dir" -N -e \
        "SELECT DISTINCT User FROM mysql.user WHERE Host='${old_sub}' AND User NOT IN ('root','mariadb.sys','mysql','${skip_user}') AND User<>'';" \
        2>/dev/null | tr -d '\r')
    [[ -n "$users" ]] || return 0

    info "检测到绑定在旧网段(${old_sub})的其他账号，尝试自动克隆授权到新网段(${new_wg_sub} / ${docker_sub})..."
    local u ok=0 fail=0
    while IFS= read -r u; do
        [[ -n "$u" ]] || continue
        local create_stmt
        create_stmt=$(db_exec "$dir" -N -e "SHOW CREATE USER '${u}'@'${old_sub}';" 2>/dev/null | tr -d '\r')
        if [[ -z "$create_stmt" ]]; then
            warn "读取账号 ${u}@${old_sub} 的凭据失败，跳过（请手动检查）"; ((fail++)); continue
        fi
        local grants
        grants=$(db_exec "$dir" -N -e "SHOW GRANTS FOR '${u}'@'${old_sub}';" 2>/dev/null | tr -d '\r')

        local from="'${u}'@'${old_sub}'" to_wg="'${u}'@'${new_wg_sub}'" to_docker="'${u}'@'${docker_sub}'"
        db_exec "$dir" -e "${create_stmt//$from/$to_wg}" 2>/dev/null
        db_exec "$dir" -e "${create_stmt//$from/$to_docker}" 2>/dev/null

        local ok_grant=1
        while IFS= read -r g; do
            [[ -n "$g" ]] || continue
            db_exec "$dir" -e "${g//$from/$to_wg};"     2>/dev/null || ok_grant=0
            db_exec "$dir" -e "${g//$from/$to_docker};" 2>/dev/null || ok_grant=0
        done <<< "$grants"

        if (( ok_grant )); then ((ok++)); else warn "账号 ${u} 的部分权限克隆可能失败，请用 list-db/SHOW GRANTS 复核"; ((fail++)); fi
    done <<< "$users"

    db_exec "$dir" -e "FLUSH PRIVILEGES;" 2>/dev/null || true
    (( ok   > 0 )) && log "✓ 已尝试克隆 ${ok} 个账号的授权到新网段（旧网段账号未删除，确认无用后可自行清理）"
    (( fail > 0 )) && warn "有 ${fail} 个账号克隆不完整，请务必用 list-db 或直接 SHOW GRANTS 手动核查"
    warn "该操作只覆盖 Host 恰为 '${old_sub}' 的账号；如有其他 host 模式的自建账号，不在此范围内，请手动核对。"
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
    if [[ "$val" == "auto" || "$val" == "AUTO" ]]; then
        _env_set "$dir" "MAX_CONNECTIONS" ""; conn=$_AT_MAX_CONN
    elif [[ -z "$val" ]]; then
        :
    elif [[ "$val" =~ ^[0-9]+$ ]]; then
        # 强制按十进制解析，避免 010 这类前导零被 (( )) 当成八进制导致报错/误判
        local val_dec=$((10#$val))
        if (( val_dec >= 10 && val_dec <= 10000 )); then
            _env_set "$dir" "MAX_CONNECTIONS" "$val_dec"; conn="$val_dec"
        else
            warn "范围 10-10000，跳过"
        fi
    else
        warn "需要数字，跳过"
    fi

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
    # 每个 DIR 独立的 known_hosts：首次连接时按 TOFU 方式记录并锁定远端 host key，
    # 后续如果 host key 发生变化（可能是中间人攻击）会直接拒绝连接，
    # 而不是像 StrictHostKeyChecking=no 那样完全不做校验。
    RSYNC_KNOWN_HOSTS="${dir}/.rsync_known_hosts"
    touch "$RSYNC_KNOWN_HOSTS" 2>/dev/null
    chmod 600 "$RSYNC_KNOWN_HOSTS" 2>/dev/null || true
}

# 构建 rsync SSH 选项数组
_rsync_ssh_opts() {
    local key="${RSYNC_KEY:-}" port="${RSYNC_PORT:-22}"
    local khf="${RSYNC_KNOWN_HOSTS:-/dev/null}"
    local ssh_cmd="ssh -p ${port} -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=${khf} -o BatchMode=yes"
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
    # 强制以目录形式结尾：若远端目录尚不存在（如全新机器首次推送），
    # 不带斜杠会被 rsync 当作单文件目标、直接建成同名文件而不是目录。
    remote_dest="${remote_dest%/}/"
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
    mkdir -p "$local_dest"; chmod 700 "$local_dest" 2>/dev/null || true

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
    $ssh_cmd \
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
        local khf="${dir}/.rsync_known_hosts"; touch "$khf" 2>/dev/null; chmod 600 "$khf" 2>/dev/null || true
        if ssh -p "${RSYNC_PORT:-22}" "${key_opt[@]}" \
               -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile="$khf" -o BatchMode=yes \
               -o ConnectTimeout=10 \
               "${RSYNC_USER}@${RSYNC_REMOTE}" "echo OK" 2>/dev/null | grep -q OK; then
            log "✓ SSH 连通正常（host key 已记录到 ${khf}）"
        else
            warn "✗ SSH 连接失败，请检查主机/用户/密钥/端口配置"
        fi
    fi
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
    # 注意：此函数可能被 _alist_fetch_file 用 $(...) 捕获 stdout 作为返回路径，
    # 这里的日志必须写到 stderr，否则会污染调用方捕获的返回值。
    log "✓ 下载: ${fname}  ($(du -sh "$out" | cut -f1))" >&2
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
        "$url" 2>/dev/null) || { warn "无法连接 AList WebDAV: ${url}" >&2; return 1; }

    # 解析 href，过滤掉目录本身，只显示 .sql.gz / .sql / .tar.gz 文件
    echo "$body" \
        | grep -oP '(?<=<D:href>)[^<]+' \
        | grep -E '\.(sql|sql\.gz|tar\.gz)$' \
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
              --include='*.sql.gz' --include='*.sql' --include='*.tar.gz' --exclude='*' \
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
        done < <(find "$local_dir" -maxdepth 1 \( -name '*.sql.gz' -o -name '*.sql' -o -name '*.tar.gz' \) -print0)
        (( failed == 0 )) && log "全部上传完成" || { warn "${failed} 个文件上传失败"; return 1; }
        ;;
    esac
}

# ── 统一对外接口：上传单个文件到 AList（用于全量备份归档）────
#   与 _alist_push 不同，这里只推送指定的单个文件，不会扫描并
#   重新上传目录下其它历史备份文件，避免全量备份场景下随备份数量
#   增多而重复上传（webdav 模式尤其明显，无增量跳过能力）。
# _alist_push_file DIR LOCAL_FILE [REMOTE_SUBDIR]
_alist_push_file() {
    local dir="$1" local_file="$2" remote_sub="${3:-}"
    _load_alist_conf "$dir"
    _check_alist_deps
    [[ -f "$local_file" ]] || error "文件不存在: ${local_file}"
    local remote_dir="${ALIST_REMOTE_DIR%/}${remote_sub:+/${remote_sub}}"

    case "$ALIST_MODE" in
    mount)
        _alist_check_mount "$ALIST_MOUNT"
        local dest_dir="${ALIST_MOUNT%/}/${remote_dir#/}"
        mkdir -p "$dest_dir" 2>/dev/null \
            || warn "无法在挂载点创建目录（某些只读网盘正常），继续尝试..."
        header "AList 挂载上传: ${local_file} → ${dest_dir}"
        cp "$local_file" "${dest_dir%/}/" \
            && log "上传完成 → ${dest_dir%/}/$(basename "$local_file")" \
            || error "复制到 AList 挂载目录失败"
        ;;
    webdav)
        header "AList WebDAV 上传: ${local_file} → ${ALIST_URL}/dav${remote_dir}"
        _alist_mkdir_webdav "$remote_dir"
        _alist_upload_webdav "$local_file" "$remote_dir"
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
    mkdir -p "$local_dest"; chmod 700 "$local_dest" 2>/dev/null || true

    case "$ALIST_MODE" in
    mount)
        _alist_check_mount "$ALIST_MOUNT"
        local src_dir="${ALIST_MOUNT%/}/${remote_dir#/}"
        [[ -d "$src_dir" ]] || error "AList 挂载中找不到目录: ${src_dir}"
        header "AList 挂载下载: ${src_dir} → ${local_dest}"
        rsync -av --no-perms --no-owner --no-group \
              --include='*.sql.gz' --include='*.sql' --include='*.tar.gz' --exclude='*' \
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
        ls -lht "$src" 2>/dev/null | grep -E '\.(sql|sql\.gz|tar\.gz)$' \
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
    local tmp_dir; tmp_dir=$(mktemp -d); _register_tmp "$tmp_dir"
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


# ════════════════════════════════════════════════════════════
# 备份 / 恢复
# ════════════════════════════════════════════════════════════
# cmd_backup [DIR] [DEST] [--rsync] [--alist] [--encrypt]
#   打包 .env / docker-compose.yml / mariadb-conf / redis-conf / MariaDB 全库 dump（含用户权限）/ Redis 数据
#   为单个 infra-full-backup_*.tar.gz 文件，可直接拷走；机器重装后用 restore 一条命令整体恢复。
#   --rsync   : 备份完成后自动推送到 rsync 远端（须已配置 rsync-config）
#   --alist   : 备份完成后自动上传到 AList 网盘（须已配置 alist-config）
#   --encrypt : 用 openssl 对归档再加一层对称加密（生成 .tar.gz.enc），防止远端存储被攻破后
#               密码/数据被直接读取；解密密钥务必额外单独保存，不要只依赖本机 .env
cmd_backup() {
    local do_rsync=0 do_alist=0 do_encrypt=0
    local _pos=()
    for _a in "$@"; do
        case "$_a" in
            --rsync)   do_rsync=1 ;;
            --alist)   do_alist=1 ;;
            --encrypt) do_encrypt=1 ;;
            *) _pos+=("$_a") ;;
        esac
    done
    local dir="${_pos[0]:-$DEFAULT_DIR}" dest="${_pos[1]:-${_pos[0]:-$DEFAULT_DIR}/backup}"
    _check_dir_safe "$dir"

    [[ -f "$dir/.env" ]] || error ".env 不存在，请先部署: ${dir}/.env"
    load_env "$dir"
    mkdir -p "$dest"
    chmod 700 "$dest" 2>/dev/null || true

    local ts; ts=$(date +%Y%m%d_%H%M%S)
    local work; work=$(mktemp -d); _register_tmp "$work"
    local pack="${work}/pack"; mkdir -p "$pack"

    header "全量备份 → ${dest}"

    # ── 元数据 & 配置文件 ────────────────────────────────────
    cp "$dir/.env" "$pack/.env"
    [[ -f "$dir/docker-compose.yml" ]] && cp "$dir/docker-compose.yml" "$pack/docker-compose.yml"
    [[ -d "$dir/mariadb-conf" ]] && cp -a "$dir/mariadb-conf" "$pack/mariadb-conf"
    [[ -d "$dir/redis-conf"   ]] && cp -a "$dir/redis-conf"   "$pack/redis-conf"

    cat > "$pack/manifest.txt" <<EOF
backup_time=$(date -Iseconds)
hostname=$(hostname)
DEPLOY_DB=${DEPLOY_DB:-0}
DEPLOY_REDIS=${DEPLOY_REDIS:-0}
WG_IP=${WG_IP:-}
MARIADB_IMAGE=${MARIADB_IMAGE}
REDIS_IMAGE=${REDIS_IMAGE}
EOF

    # ── MariaDB 全量导出（含所有库 + 用户 + 权限） ────────────
    if [[ "${DEPLOY_DB:-0}" == "1" ]]; then
        _svc_exists "$dir" "db" || { rm -rf "$work"; error "manifest 标记部署了 MariaDB，但 compose 中无 db 服务"; }

        # --single-transaction 只能保证 InnoDB 表在整个 dump 期间的一致性快照，
        # 对 MyISAM/Aria/MEMORY 等非事务引擎完全没有保护（既不加锁也没有快照）。
        # 而 --single-transaction 与 --lock-tables 是互斥的：LOCK TABLES 会隐式提交，
        # 反而破坏事务快照，两者不能同时生效。所以这里先探测一下，按需二选一：
        #   全库都是 InnoDB → --single-transaction（不阻塞任何写入）
        #   存在非 InnoDB 表 → 改用 --lock-tables（dump 到某个库时，短暂锁该库全部
        #                       表，其余库不受影响；比 --lock-all-tables 温和）
        local non_innodb; non_innodb=$(db_exec "$dir" -N -e \
            "SELECT COUNT(*) FROM information_schema.tables WHERE TABLE_SCHEMA NOT IN ('information_schema','performance_schema') AND ENGINE IS NOT NULL AND ENGINE<>'InnoDB';" \
            2>/dev/null | tr -d '\r')
        local dump_lock_opt="--single-transaction"
        if [[ "$non_innodb" =~ ^[0-9]+$ ]] && (( non_innodb > 0 )); then
            warn "检测到 ${non_innodb} 张非 InnoDB 表（MyISAM/Aria/MEMORY 等），--single-transaction 无法覆盖它们的一致性；"
            warn "自动改用 --lock-tables：dump 到某个库时会短暂锁住该库全部表（阻塞该库写入，其它库不受影响）。"
            dump_lock_opt="--lock-tables"
        else
            info "全部为 InnoDB 表，使用 --single-transaction（dump 期间不阻塞任何写入）"
        fi

        info "导出全部数据库（含用户/权限）..."
        if compose_run "$dir" exec -T -e MYSQL_PWD="${MARIADB_ROOT_PASSWORD}" \
                db mariadb-dump -uroot --all-databases "$dump_lock_opt" \
                --routines --triggers --events --hex-blob \
            | gzip > "${pack}/mariadb-all-databases.sql.gz"; then
            log "✓ MariaDB 导出完成 ($(du -sh "${pack}/mariadb-all-databases.sql.gz" | cut -f1))"
            echo "MARIADB_DUMP_MODE=${dump_lock_opt}" >> "${pack}/manifest.txt"
        else
            rm -rf "$work"; error "MariaDB 全量导出失败"
        fi
    fi

    # ── Redis 数据快照：整目录打包（dump.rdb + appendonlydir） ─
    #   redis.conf 固定 appendonly yes，Redis 启动时以 appendonlydir 为准加载数据，
    #   只备份/恢复 dump.rdb 不会被实际加载（已实测验证）。因此这里触发 BGREWRITEAOF
    #   压缩 AOF、确保数据完整落盘后，把整个数据目录（dump.rdb + appendonlydir）打包，
    #   恢复时原样落盘即可保证数据一致。
    #   注意：tar 打包不是原子操作。若打包过程中恰好又发生一次 AOF 重写/文件轮换
    #   （无论是自动触发还是外部手动 BGREWRITEAOF），manifest 与实际文件可能出现
    #   瞬时不一致，恢复时 Redis 会直接启动失败（已实测复现：
    #   "Unable to obtain the AOF file ... length: No such file or directory"）。
    #   下面通过打包期间临时关闭自动重写 + 打包后校验 manifest 完整性来规避。
    if [[ "${DEPLOY_REDIS:-0}" == "1" ]]; then
        if _svc_exists "$dir" "redis"; then
            local _redis_cli=(compose_run "$dir" exec -T redis redis-cli -a "${REDIS_PASSWORD}" --no-auth-warning)

            info "触发 Redis BGREWRITEAOF（压缩 AOF，确保数据完整落盘）..."
            "${_redis_cli[@]}" BGREWRITEAOF >/dev/null 2>&1 \
                || warn "BGREWRITEAOF 触发失败，继续尝试打包现有数据"
            local waited=0 in_progress
            while (( waited < 60 )); do
                in_progress=$("${_redis_cli[@]}" INFO persistence 2>/dev/null \
                    | grep -m1 '^aof_rewrite_in_progress:' | tr -d '\r' | cut -d: -f2)
                [[ "$in_progress" == "0" || -z "$in_progress" ]] && break
                sleep 1; (( waited++ ))
            done
            (( waited >= 60 )) && warn "Redis BGREWRITEAOF 未在 60 秒内确认完成，快照可能不是最新"

            # 打包期间临时关闭自动 AOF 重写，避免打包过程中再触发一次文件轮换
            local _orig_aofpct
            _orig_aofpct=$("${_redis_cli[@]}" CONFIG GET auto-aof-rewrite-percentage 2>/dev/null \
                | tail -1 | tr -d '\r')
            "${_redis_cli[@]}" CONFIG SET auto-aof-rewrite-percentage 0 >/dev/null 2>&1 \
                || warn "无法临时关闭 Redis 自动 AOF 重写，打包期间存在极小概率的竞态风险"

            # 额外触发一次 BGSAVE，保留独立 dump.rdb 便于手工排查/兼容旧版恢复逻辑
            "${_redis_cli[@]}" BGSAVE >/dev/null 2>&1 || true

            if [[ -d "$dir/redis" ]]; then
                tar -C "$dir" -czf "${pack}/redis-data.tar.gz" redis \
                    && log "✓ Redis 数据目录打包完成 ($(du -sh "${pack}/redis-data.tar.gz" | cut -f1))" \
                    || warn "Redis 数据打包失败，恢复时该库将为空"

                # 校验：manifest 引用的每个文件是否都被完整打入归档；
                # 若缺失，说明打包期间撞上了文件轮换竞态，重试一次
                local _manifest="$dir/redis/appendonlydir/appendonly.aof.manifest"
                if [[ -f "$_manifest" && -f "${pack}/redis-data.tar.gz" ]]; then
                    local _tar_list; _tar_list=$(tar -tzf "${pack}/redis-data.tar.gz" 2>/dev/null)
                    local _bad=0 _key _fname _rest
                    while read -r _key _fname _rest; do
                        [[ "$_key" == "file" ]] || continue
                        grep -qF "redis/appendonlydir/${_fname}" <<< "$_tar_list" \
                            || { warn "打包校验：manifest 引用的 ${_fname} 未完整打入归档（疑似与 AOF 重写竞态），重试打包..."; _bad=1; }
                    done < "$_manifest"
                    if (( _bad )); then
                        sleep 1
                        tar -C "$dir" -czf "${pack}/redis-data.tar.gz" redis \
                            && log "✓ 重新打包完成 ($(du -sh "${pack}/redis-data.tar.gz" | cut -f1))" \
                            || warn "重新打包仍失败，请人工核查该份备份的 Redis 数据完整性"
                    fi
                fi
            else
                warn "Redis 数据目录不存在，跳过"
            fi

            # 恢复自动 AOF 重写的原有配置
            if [[ -n "${_orig_aofpct:-}" ]]; then
                "${_redis_cli[@]}" CONFIG SET auto-aof-rewrite-percentage "${_orig_aofpct}" >/dev/null 2>&1 || true
            fi
        else
            warn "manifest 标记部署了 Redis（DEPLOY_REDIS=1），但 compose 中无 redis 服务，跳过 Redis 备份"
        fi
    fi

    if [[ "${DEPLOY_DB:-0}" != "1" && "${DEPLOY_REDIS:-0}" != "1" ]]; then
        rm -rf "$work"; error "未检测到已部署的 MariaDB/Redis（DEPLOY_DB/DEPLOY_REDIS 均为空），无内容可备份"
    fi

    # ── 打包为单一归档 ────────────────────────────────────────
    local out="${dest}/infra-full-backup_${ts}.tar.gz"
    ( umask 077; tar -C "$pack" -czf "$out" . ) || { rm -rf "$work"; error "打包失败"; }
    chmod 600 "$out" 2>/dev/null || warn "无法收紧备份文件权限，该文件含明文密码，请手动 chmod 600"
    rm -rf "$work"
    log "全量备份完成: ${out}  ($(du -sh "$out" | cut -f1))"

    # ── 可选：加密归档 ────────────────────────────────────────
    #   传输/权限保护（chmod 600、SSH 加密）只能防"路上被截获"或"本机其他用户偷看"，
    #   防不住"远端存储介质本身被攻破"（比如 rsync 服务器或网盘账号泄露）。
    #   --encrypt 用 openssl 对归档再加一层对称加密，远端拿到的只是密文。
    if (( do_encrypt )); then
        command -v openssl >/dev/null 2>&1 || error "加密需要 openssl，请先安装"
        load_env "$dir"
        local enc_key="${BACKUP_ENC_KEY:-}" _generated=0
        if [[ -z "$enc_key" ]]; then
            enc_key=$(randpw); _generated=1
            _env_set "$dir" "BACKUP_ENC_KEY" "$enc_key"
        fi
        local enc_out="${out}.enc"
        if openssl enc -aes-256-cbc -pbkdf2 -iter 200000 -salt \
                -pass "pass:${enc_key}" -in "$out" -out "$enc_out"; then
            command -v shred >/dev/null 2>&1 && shred -u "$out" 2>/dev/null || rm -f "$out"
            chmod 600 "$enc_out" 2>/dev/null || true
            out="$enc_out"
            log "✓ 已加密: ${out}"
        else
            error "备份加密失败"
        fi
        echo
        _c "1;31" "════════════════════════════════════════════════════════"
        _c "1;31" "  重要：备份解密密钥（务必单独抄录保存，不要只依赖本机 .env）"
        _c "1;31" "  ${enc_key}"
        if (( _generated )); then
            _c "1;31" "  已顺手写入 ${dir}/.env 的 BACKUP_ENC_KEY，方便本机后续备份复用；"
        fi
        _c "1;31" "  但机器重装后 .env 会随之丢失，到时候 restore 这份备份必须"
        _c "1;31" "  手动提供上面这个密钥，请现在就把它记录到密码管理器/纸面等独立位置。"
        _c "1;31" "════════════════════════════════════════════════════════"
        echo
    fi

    info "该文件可直接拷走保存；机器重装后执行 restore 即可整体恢复。"

    # ── 可选 rsync 推送 ──────────────────────────────────────
    if (( do_rsync )); then
        header "推送备份到 rsync 远端"
        _rsync_push "$dir" "$out" ""
    fi

    # ── 可选 AList 上传 ───────────────────────────────────────
    if (( do_alist )); then
        header "上传备份到 AList 网盘"
        _alist_push_file "$dir" "$out"
    fi
}

# cmd_restore [DIR] <备份tar.gz|rsync://user@host[:port]/path/file|alist:///path/file>
#   适用于机器重装：给出全量备份归档，即可在目标 DIR 重建 .env/配置、拉起容器、
#   导入全库 SQL（含用户权限）、恢复 Redis 数据，并按当前机器的 WireGuard IP 重新授权。
cmd_restore() {
    local dir="${1:-$DEFAULT_DIR}" f="${2:?用法: restore [DIR] <infra-full-backup_*.tar.gz[.enc]|rsync://...|alist:///...> [解密密钥]}"
    local enc_key="${3:-}"
    _check_dir_safe "$dir"

    # ── 支持 rsync:// URI：先拉取到临时目录再恢复 ───────────
    local _tmp_dir="" _cleanup=0
    if [[ "$f" == rsync://* ]]; then
        _check_rsync
        _parse_rsync_uri "$f"   # 设置 RSYNC_URI_{USER,HOST,PORT,PATH}
        _tmp_dir=$(mktemp -d); _register_tmp "$_tmp_dir"
        _cleanup=1
        local _fname; _fname=$(basename "$RSYNC_URI_PATH")
        mkdir -p "$dir"
        local _khf="${dir}/.rsync_known_hosts"; touch "$_khf" 2>/dev/null; chmod 600 "$_khf" 2>/dev/null || true
        local _ssh_cmd="ssh -p ${RSYNC_URI_PORT} -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=${_khf} -o BatchMode=yes"
        [[ -n "${RSYNC_KEY:-}" ]] && _ssh_cmd+=" -i ${RSYNC_KEY}"
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
        local _alist_path="${f#alist://}"
        # 归一化为单个前导 /：兼容标准 alist:///path（本身已含一个 /）
        # 和少写一个斜杠的 alist://path 两种写法
        [[ "$_alist_path" == /* ]] || _alist_path="/${_alist_path}"
        info "从 AList 网盘获取文件: ${_alist_path}"
        local _fetched; _fetched=$(_alist_fetch_file "$dir" "$_alist_path")
        _tmp_dir=$(dirname "$_fetched")
        _register_tmp "$_tmp_dir"
        _cleanup=1
        f="$_fetched"
        log "已从 AList 下载到临时目录: ${f}"
    fi

    [[ -f "$f" ]] || { [[ $_cleanup -eq 1 ]] && rm -rf "$_tmp_dir"; error "文件不存在: ${f}"; }

    # ── 支持 .enc 加密归档：先解密到临时文件，再走原有校验/解压流程 ─
    if [[ "$f" == *.enc ]]; then
        command -v openssl >/dev/null 2>&1 \
            || { [[ $_cleanup -eq 1 ]] && rm -rf "$_tmp_dir"; error "解密需要 openssl，请先安装"; }
        if [[ -z "$enc_key" ]]; then
            # 换机重装场景下 .env 通常还不存在，密钥不可能从本地读到，必须交互输入
            read -rsp "该备份已加密，请输入解密密钥: " enc_key; echo
        fi
        [[ -n "$enc_key" ]] \
            || { [[ $_cleanup -eq 1 ]] && rm -rf "$_tmp_dir"; error "未提供解密密钥，无法继续"; }
        local _dec_dir; _dec_dir=$(mktemp -d); _register_tmp "$_dec_dir"
        local _dec_file="${_dec_dir}/$(basename "${f%.enc}")"
        if ! openssl enc -d -aes-256-cbc -pbkdf2 -iter 200000 \
                -pass "pass:${enc_key}" -in "$f" -out "$_dec_file" 2>/dev/null; then
            rm -rf "$_dec_dir"
            [[ $_cleanup -eq 1 ]] && rm -rf "$_tmp_dir"
            error "解密失败，密钥可能不正确"
        fi
        [[ $_cleanup -eq 1 ]] && rm -rf "$_tmp_dir"
        _tmp_dir="$_dec_dir"; _cleanup=1
        f="$_dec_file"
        log "解密成功"
    fi

    tar -tzf "$f" >/dev/null 2>&1 \
        || { [[ $_cleanup -eq 1 ]] && rm -rf "$_tmp_dir"; error "不是有效的 tar.gz 备份归档: ${f}"; }

    local extract; extract=$(mktemp -d); _register_tmp "$extract"
    tar -C "$extract" -xzf "$f" \
        || { rm -rf "$extract"; [[ $_cleanup -eq 1 ]] && rm -rf "$_tmp_dir"; error "解压失败: ${f}"; }
    [[ $_cleanup -eq 1 ]] && rm -rf "$_tmp_dir"
    [[ -f "$extract/.env" ]] || { rm -rf "$extract"; error "备份归档中缺少 .env，不是有效的全量备份文件"; }

    header "全量恢复 → ${dir}"
    if [[ -f "$extract/manifest.txt" ]]; then
        echo; cat "$extract/manifest.txt" | sed 's/^/  /'; echo
    fi

    [[ -f "$dir/.env" ]] && warn "目标目录已存在 .env，恢复将覆盖现有配置，MariaDB/Redis 数据将被备份内容整体替换！"
    read -rp "确认恢复到 ${dir}？[y/N] " c
    if [[ "${c,,}" != "y" ]]; then
        info "已取消"; rm -rf "$extract"; return
    fi
    [[ $EUID -eq 0 ]] || { rm -rf "$extract"; error "需要 root 权限"; }

    # ── 若目标目录已有旧部署，先停止 ─────────────────────────
    if [[ -f "$dir/docker-compose.yml" ]]; then
        info "停止现有服务..."
        compose_run "$dir" down 2>/dev/null || true
    fi

    mkdir -p "$dir"
    cp "$extract/.env" "$dir/.env"; chmod 600 "$dir/.env"
    [[ -f "$extract/docker-compose.yml" ]] && cp "$extract/docker-compose.yml" "$dir/docker-compose.yml"
    [[ -d "$extract/mariadb-conf" ]] && { rm -rf "$dir/mariadb-conf"; cp -a "$extract/mariadb-conf" "$dir/mariadb-conf"; }
    [[ -d "$extract/redis-conf"   ]] && { rm -rf "$dir/redis-conf";   cp -a "$extract/redis-conf"   "$dir/redis-conf";   }

    load_env "$dir"
    local old_wg_ip="${WG_IP:-}"

    # ── 新机器 WireGuard IP 可能与备份中不同，检测并更新 ──────
    local new_wg_ip
    if new_wg_ip=$(get_wg_ip 2>/dev/null) && [[ -n "$new_wg_ip" ]]; then
        if [[ "$new_wg_ip" != "${WG_IP:-}" ]]; then
            warn "当前 WG IP (${new_wg_ip}) 与备份记录 (${WG_IP:-无}) 不同，已更新 .env"
            _env_set "$dir" "WG_IP" "$new_wg_ip"
        fi
    else
        warn "无法获取当前 WireGuard IP，沿用备份中的 WG_IP=${WG_IP:-无}（请确认 WireGuard 已启动）"
    fi
    load_env "$dir"
    _write_compose "$dir"   # 按当前脚本版本重新生成 compose，保证与 DEPLOY_DB/DEPLOY_REDIS 一致

    # ── MariaDB：清空后由容器全新初始化 + 导入全量 SQL ────────
    if [[ "${DEPLOY_DB:-0}" == "1" ]]; then
        [[ -f "$extract/mariadb-all-databases.sql.gz" ]] \
            || warn "备份标记 DEPLOY_DB=1，但归档中缺少 mariadb-all-databases.sql.gz！继续将清空现有数据目录，MariaDB 将以空库启动，请确认这是你想要的行为。"
        rm -rf "$dir/db"; mkdir -p "$dir/db"
    fi

    # ── Redis：直接恢复数据文件（容器启动前落盘）─────────────
    #   优先恢复 RDB 快照（新版备份格式）；若备份来自旧版脚本（整目录 tar），
    #   则按旧格式解压，保证历史备份文件仍可正常恢复。
    if [[ "${DEPLOY_REDIS:-0}" == "1" ]]; then
        rm -rf "$dir/redis"; mkdir -p "$dir/redis"
        if [[ -f "$extract/redis-data.tar.gz" ]]; then
            info "恢复 Redis 数据目录（dump.rdb + appendonlydir）..."
            tar -C "$dir" -xzf "$extract/redis-data.tar.gz" \
                || warn "Redis 数据解压失败，Redis 将以空数据启动"
        elif [[ -f "$extract/redis-dump.rdb.gz" ]]; then
            warn "检测到旧版备份格式（仅 dump.rdb，无 appendonlydir）。"
            warn "当前 redis.conf 固定启用 appendonly，Redis 启动时会优先按 AOF 加载数据，"
            warn "仅恢复 dump.rdb 大概率不会生效、Redis 将以空数据启动，请知悉并尽快用新版重新备份。"
            gzip -dc "$extract/redis-dump.rdb.gz" > "$dir/redis/dump.rdb" \
                || warn "Redis RDB 恢复失败，Redis 将以空数据启动"
        else
            warn "备份中无 Redis 数据文件，Redis 将以空数据启动"
        fi
    fi

    local svcs=()
    [[ "${DEPLOY_DB:-0}"    == "1" ]] && svcs+=("db")
    [[ "${DEPLOY_REDIS:-0}" == "1" ]] && svcs+=("redis")
    [[ ${#svcs[@]} -gt 0 ]] || { rm -rf "$extract"; error "备份未标记任何已部署服务（DEPLOY_DB/DEPLOY_REDIS）"; }

    header "启动服务: ${svcs[*]}"
    compose_run "$dir" up -d --wait "${svcs[@]}" 2>&1 \
        || { rm -rf "$extract"; error "docker compose up 失败"; }

    # ── 导入 MariaDB 全量数据（含所有库/用户/权限） ──────────
    if [[ "${DEPLOY_DB:-0}" == "1" && -f "$extract/mariadb-all-databases.sql.gz" ]]; then
        info "导入全量 SQL，可能需要几分钟..."
        if gzip -dc "$extract/mariadb-all-databases.sql.gz" \
                | compose_run "$dir" exec -T -e MYSQL_PWD="${MARIADB_ROOT_PASSWORD}" db mariadb -uroot; then
            log "✓ MariaDB 数据导入完成"
        else
            warn "✗ MariaDB 数据导入过程中出现错误，请检查日志"
        fi
        db_exec "$dir" -e "FLUSH PRIVILEGES;" 2>/dev/null || true

        # WG/Docker 网段可能因换机而变化，刷新主库/用户授权
        if [[ -n "${MARIADB_DATABASE:-}" && -n "${MARIADB_USER:-}" && -n "${MARIADB_PASSWORD:-}" ]]; then
            _grant_wg "$dir" "${MARIADB_DATABASE}" "${MARIADB_USER}" "${MARIADB_PASSWORD}" "${WG_IP}" \
                || warn "主库授权刷新失败，请手动检查"
        fi

        # 其他账号（如 add-db 创建的）没有明文密码可用，尽力而为按 host 模式自动克隆
        if [[ -n "$old_wg_ip" ]]; then
            local docker_sub_now; docker_sub_now=$(_docker_subnet)
            _reauth_extra_users "$dir" "${old_wg_ip%.*}.%" "${WG_IP%.*}.%" "$docker_sub_now" "${MARIADB_USER:-}" \
                || warn "自动克隆其他账号授权时出错，请手动检查"
        fi
        warn "若之前通过 add-db 创建了其他库/用户，恢复完成后仍建议运行 list-db 复核一遍授权是否正常。"
    elif [[ "${DEPLOY_DB:-0}" == "1" ]]; then
        warn "未导入任何 MariaDB 数据（归档缺少 mariadb-all-databases.sql.gz），MariaDB 当前为全新空库！"
    fi

    rm -rf "$extract"
    compose_run "$dir" ps
    log "全量恢复完成"
    _print_creds "$dir"
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
        echo "  说明：全量备份 = .env+配置+MariaDB全库(含用户权限)+Redis数据，打包为单个 tar.gz"
        echo "        备份时可选加密（生成 .tar.gz.enc），远端/网盘被攻破也只是密文，密钥务必额外保存"
        echo "        文件可直接拷走；机器重装后用「全量恢复」一步整体拉起。"
        echo "  ─────────────────────────────────────────────"
        echo "  1) 全量备份"
        echo "  2) 全量恢复"
        echo "  3) 远端配置（rsync / AList，仅推送/拉取备份时需要）"
        echo "  ─────────────────────────────────────────────"
        echo "  0) 返回"
        echo
        read -rp "  请选择 [0-3]: " CH
        case "$CH" in
            1) menu_bk_backup        ;;
            2) menu_bk_restore       ;;
            3) menu_bk_remote_config ;;
            0) return ;;
            *) warn "无效选项"; sleep 1 ;;
        esac
    done
}

menu_bk_backup() {
    _db_menu_head "全量备份"
    echo "  保存位置？"
    echo "  1) 仅本地"
    echo "  2) 本地 + 推送到 rsync 远端"
    echo "  3) 本地 + 上传到 AList 网盘"
    read -rp "  请选择 [1-3，默认 1]: " LOC_CH
    local _flags=()
    case "$LOC_CH" in
        2) load_env "$DIR"
           if [[ -z "${RSYNC_REMOTE:-}" ]]; then
               warn "尚未配置 rsync 远端，先去配置一下"; menu_bk_remote_config_rsync
               load_env "$DIR"; [[ -z "${RSYNC_REMOTE:-}" ]] && { warn "未完成配置，本次改为仅本地备份"; }
           fi
           [[ -n "${RSYNC_REMOTE:-}" ]] && _flags+=("--rsync") ;;
        3) load_env "$DIR"
           if [[ -z "${ALIST_URL:-}" && -z "${ALIST_MOUNT:-}" ]]; then
               warn "尚未配置 AList 网盘，先去配置一下"; menu_bk_remote_config_alist
               load_env "$DIR"
               [[ -z "${ALIST_URL:-}" && -z "${ALIST_MOUNT:-}" ]] && { warn "未完成配置，本次改为仅本地备份"; }
           fi
           [[ -n "${ALIST_URL:-}" || -n "${ALIST_MOUNT:-}" ]] && _flags+=("--alist") ;;
        *) : ;;  # 仅本地
    esac
    _ask "本地输出目录" DEST "${DIR}/backup"
    read -rp "  是否加密备份归档？[y/N]（推荐；密钥请务必额外保存） " ENC_YN; echo
    [[ "${ENC_YN,,}" == "y" ]] && _flags+=("--encrypt")
    _menu_run cmd_backup "$DIR" "$DEST" "${_flags[@]}" || true; _pause
}

menu_bk_restore() {
    _db_menu_head "全量恢复"
    info "支持机器重装后的场景：DIR 可以是全新目录，将从备份归档重建全部配置和数据"
    echo "  备份来源？"
    echo "  1) 本地文件"
    echo "  2) rsync 远端"
    echo "  3) AList 网盘"
    read -rp "  请选择 [1-3，默认 1]: " SRC_CH
    local BK_FILE=""
    case "$SRC_CH" in
        2)
            load_env "$DIR" 2>/dev/null || true
            info "正在列出 rsync 远端目录..."
            ( _load_rsync_conf "$DIR" 2>/dev/null && _rsync_list "$DIR" 2>/dev/null ) \
                || warn "无法列出远端文件（请确认已在「远端配置」里配置过 rsync）"
            echo
            _ask "远端文件路径（rsync://user@host[:port]/path/infra-full-backup_*.tar.gz[.enc]）" BK_FILE ""
            ;;
        3)
            load_env "$DIR" 2>/dev/null || true
            info "正在列出 AList 网盘目录..."
            ( _alist_list "$DIR" 2>/dev/null ) \
                || warn "无法列出网盘文件（请确认已在「远端配置」里配置过 AList）"
            echo
            echo "  输入格式: alist:///AList内部路径/文件名.tar.gz"
            _ask "AList 文件路径（alist:///...）" BK_FILE ""
            ;;
        *)
            _ask "全量备份文件（infra-full-backup_*.tar.gz 或 .tar.gz.enc）" BK_FILE ""
            ;;
    esac
    [[ -n "$BK_FILE" ]] || { warn "不能为空"; _pause; return; }
    echo; _menu_run cmd_restore "$DIR" "$BK_FILE" || true; _pause
}

# ── 远端配置：rsync / AList 二选一进入对应的配置向导 ─────────
menu_bk_remote_config() {
    _mhdr; _c "1;33" "  ▶ 远端配置"; echo
    echo "  1) 配置 / 测试 rsync 远端"
    echo "  2) 配置 / 测试 AList 网盘"
    echo "  0) 返回"
    echo
    read -rp "  请选择 [0-2]: " CH
    case "$CH" in
        1) menu_bk_remote_config_rsync ;;
        2) menu_bk_remote_config_alist ;;
        0) return ;;
        *) warn "无效选项"; sleep 1 ;;
    esac
}

menu_bk_remote_config_rsync() {
    _db_menu_head "配置 rsync 远端"
    _menu_run cmd_rsync_config "$DIR" || true; _pause
}

menu_bk_remote_config_alist() {
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
        rsync-config) cmd_rsync_config "$@" ;;
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