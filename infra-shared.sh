#!/usr/bin/env bash
# ============================================================
# infra-shared.sh — 共享 MariaDB + Redis（仅监听 WireGuard 网口）
#
# 用法：
#   bash infra-shared.sh <子命令> [参数...]
#
# 子命令：
#   deploy  [DIR] [WG_IP]   部署 MariaDB + Redis
#   add-db  [DIR] <DB> <USER> <PW>
#                           在运行中的 MariaDB 新建库和用户
#   del-db  [DIR] <DB> <USER>
#                           删除库和用户
#   list-db [DIR]           列出所有业务库和用户
#   passwd  [DIR] <USER> <NEW_PW>
#                           修改用户密码
#   status  [DIR]           显示运行状态
#   backup  [DIR] [DEST]    备份所有库到本地目录
#   restore [DIR] <SQL文件>  恢复单个库
#   stop    [DIR]           停止服务
#   start   [DIR]           启动服务
#   logs    [DIR] <db|redis> 查看日志
#
# 前置条件：
#   - WireGuard 已启动（wg0 接口存在）
#   - docker compose v2 已安装
#
# WG_IP 默认读取 wg0 接口当前地址，也可显式传入
# ============================================================
set -euo pipefail
export LANG=en_US.UTF-8
export LC_ALL=en_US.UTF-8

# ── 默认值 ──────────────────────────────────────────────────
export DEFAULT_DIR="${BASE_DIR:-/srv}/infra"
export WG_IFACE="${WG_IFACE:-wg0}"
export MARIADB_PORT="${MARIADB_PORT:-3306}"
export REDIS_PORT="${REDIS_PORT:-6379}"
export MARIADB_IMAGE="${MARIADB_IMAGE:-mariadb:11}"
export REDIS_IMAGE="${REDIS_IMAGE:-redis:7-alpine}"

# ── 颜色输出 ────────────────────────────────────────────────
_c()     { printf "\033[${1}m${2}\033[0m\n"; }
log()    { _c "32"   "[OK]  $*"; }
info()   { _c "36"   "[..] $*"; }
warn()   { _c "33"   "[!!] $*"; }
error()  { _c "31"   "[EE] $*"; exit 1; }
header() { echo; _c "1;34" "══ $* ══"; }

# 修复 #10：去掉 `true` 掩盖 SIGPIPE 的做法，改用 2>/dev/null 抑制
# tr 因 head 关闭管道收到 SIGPIPE 本属正常，重定向 stderr 即可。
randpw() {
    LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom 2>/dev/null | head -c 32
}

# ── 获取 WireGuard 接口 IP ──────────────────────────────────
get_wg_ip() {
    local IP
    IP=$(ip addr show "${WG_IFACE}" 2>/dev/null \
        | awk '/inet /{gsub(/\/.*/, "", $2); print $2; exit}')
    [[ -n "$IP" ]] || error "无法获取 ${WG_IFACE} IP，请确认 WireGuard 已启动"
    echo "$IP"
}

# ── 读取 .env（仅在当前 shell，不导出到子进程环境）──────────
load_env() {
    local DIR="$1"
    [[ -f "$DIR/.env" ]] || error ".env 不存在: $DIR/.env"
    # shellcheck disable=SC1090
    source "$DIR/.env"
}

# ── compose 快捷执行 ────────────────────────────────────────
# 修复 #13：避免函数名遮蔽系统 dc(1) 命令，改名为 compose_run
compose_run() {
    local DIR="$1"; shift
    docker compose -f "$DIR/docker-compose.yml" --env-file "$DIR/.env" "$@"
}

# ── MariaDB 执行 SQL ────────────────────────────────────────
# 修复 #4：去掉宿主机侧无效的 MYSQL_PWD 前置赋值，
# 仅通过 docker compose exec -e 将变量注入容器内进程。
mariadb_exec() {
    local DIR="$1"; shift
    load_env "$DIR"
    compose_run "$DIR" exec -T \
        -e MYSQL_PWD="${MARIADB_ROOT_PASSWORD}" \
        db mariadb -uroot "$@"
}

# ── 等待 MariaDB 就绪 ───────────────────────────────────────
# 修复 #7：调用者已 load_env，内部不再重复 source；
# 改为接收密码参数，避免依赖外部变量状态。
wait_db_ready() {
    local DIR="$1"
    local ROOT_PW="$2"
    local RETRIES="${3:-20}"
    info "等待 MariaDB 就绪..."
    while ! compose_run "$DIR" exec -T \
            -e MYSQL_PWD="${ROOT_PW}" \
            db mariadb-admin -uroot \
            ping --silent 2>/dev/null; do
        sleep 3
        (( RETRIES-- ))
        [[ $RETRIES -gt 0 ]] || error "MariaDB 启动超时"
    done
    log "MariaDB 就绪"
}

# ── 校验标识符（库名 / 用户名）──────────────────────────────
_validate_identifier() {
    local VALUE="$1" LABEL="$2"
    [[ "$VALUE" =~ ^[A-Za-z0-9_]{1,64}$ ]] \
        || error "${LABEL} 只能包含字母、数字、下划线，长度 1-64，实际值: '${VALUE}'"
}

# ── 从 .env 解析 WG_IP，若缺失则探测接口 ───────────────────
# 修复 #1 #2：集中处理 WG_IP 获取，供 cmd_add_db / cmd_del_db 使用
_resolve_wg_ip() {
    local DIR="$1"
    local IP="${WG_IP:-}"          # load_env 可能已设置
    if [[ -z "$IP" ]]; then
        warn ".env 中未找到 WG_IP，尝试从 ${WG_IFACE} 接口获取"
        IP=$(get_wg_ip)
    fi
    echo "$IP"
}

# ════════════════════════════════════════════════════════════
# deploy [DIR] [WG_IP]
# ════════════════════════════════════════════════════════════
cmd_deploy() {
    local DIR="${1:-$DEFAULT_DIR}"
    local WG_IP="${2:-$(get_wg_ip)}"

    header "部署共享基础设施 → ${DIR}  (监听 ${WG_IP})"
    [[ $EUID -eq 0 ]] || error "需要 root 权限"

    ip link show "${WG_IFACE}" &>/dev/null || \
        error "${WG_IFACE} 接口不存在，请先启动 WireGuard"

    mkdir -p "${DIR}"/{db,redis,backup}

    if [[ ! -f "${DIR}/.env" ]]; then
        local ROOT_PW DB_PW REDIS_PW
        ROOT_PW=$(randpw)
        DB_PW=$(randpw)
        REDIS_PW=$(randpw)

        cat > "${DIR}/.env" <<EOF
# 共享基础设施凭据 — 保密，分发给各 WordPress 节点
MARIADB_ROOT_PASSWORD=${ROOT_PW}
MARIADB_DATABASE=wordpress
MARIADB_USER=wpuser
MARIADB_PASSWORD=${DB_PW}
REDIS_PASSWORD=${REDIS_PW}
WG_IP=${WG_IP}
EOF
        chmod 600 "${DIR}/.env"
        log ".env 已生成: ${DIR}/.env"
    else
        warn ".env 已存在，跳过生成密码（使用已有凭据）"
        sed -i "s|^WG_IP=.*|WG_IP=${WG_IP}|" "${DIR}/.env"
    fi

    load_env "${DIR}"

    # ── MariaDB 配置 ──────────────────────────────────────
    mkdir -p "${DIR}/mariadb-conf"
    cat > "${DIR}/mariadb-conf/custom.cnf" <<INI
[mysqld]
innodb_buffer_pool_size         = 512M
innodb_log_file_size            = 128M
innodb_flush_log_at_trx_commit  = 2
max_connections                 = 200
query_cache_type                = 0

character-set-server            = utf8mb4
collation-server                = utf8mb4_unicode_ci

bind-address                    = 0.0.0.0

slow_query_log                  = 1
slow_query_log_file             = /var/lib/mysql/slow.log
long_query_time                 = 2
INI

    # ── Redis 配置 ────────────────────────────────────────
    # 修复 #3：删除重复的 requirepass 行
    mkdir -p "${DIR}/redis-conf"
    cat > "${DIR}/redis-conf/redis.conf" <<CONF
bind 0.0.0.0
port ${REDIS_PORT}
requirepass ${REDIS_PASSWORD}

save 900 1
save 300 10
save 60  10000
appendonly yes
appendfsync everysec

maxmemory 512mb
maxmemory-policy allkeys-lru

loglevel notice
logfile ""
CONF

    # ── docker-compose.yml ────────────────────────────────
    cat > "${DIR}/docker-compose.yml" <<YAML
services:
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

    info "启动容器..."
    sysctl -w vm.overcommit_memory=1 >/dev/null 2>&1 || true
    grep -q 'vm.overcommit_memory' /etc/sysctl.conf \
        || echo 'vm.overcommit_memory = 1' >> /etc/sysctl.conf

    compose_run "${DIR}" up -d 2>&1 || error "docker compose up 失败，请检查上方错误信息"

    # 修复 #7：显式传递密码，不依赖 load_env 重复调用
    wait_db_ready "${DIR}" "${MARIADB_ROOT_PASSWORD}"

    _grant_wg_access "${DIR}" "${MARIADB_DATABASE}" "${MARIADB_USER}" "${MARIADB_PASSWORD}" "${WG_IP}"

    echo ""
    compose_run "${DIR}" ps
    log "共享基础设施部署完成"
    _print_credentials "${DIR}"
}

# ── 授权 WG 网段访问（内部使用）──────────────────────────────
_grant_wg_access() {
    local DIR="$1" DB="$2" USER="$3" PW="$4"
    local _ARG_WG_IP="${5:-}"
    load_env "$DIR"
    local WG_IP="${_ARG_WG_IP:-${WG_IP}}"
    local WG_SUBNET="${WG_IP%.*}.%"

    mariadb_exec "$DIR" <<SQL
CREATE USER IF NOT EXISTS '${USER}'@'${WG_SUBNET}' IDENTIFIED BY '${PW}';
GRANT ALL PRIVILEGES ON \`${DB}\`.* TO '${USER}'@'${WG_SUBNET}';
CREATE USER IF NOT EXISTS '${USER}'@'172.%' IDENTIFIED BY '${PW}';
GRANT ALL PRIVILEGES ON \`${DB}\`.* TO '${USER}'@'172.%';
FLUSH PRIVILEGES;
SQL
    log "已授权 ${USER}@${WG_SUBNET} 和 ${USER}@172.% 访问 ${DB}"
}

# ── 打印凭据摘要 ─────────────────────────────────────────────
# 修复 #8：改用自适应宽度，避免长值破坏表格边框
_print_credentials() {
    local DIR="$1"
    load_env "$DIR"

    local DB_ADDR="${WG_IP}:${MARIADB_PORT}"
    local RE_ADDR="${WG_IP}:${REDIS_PORT}"

    echo ""
    echo "┌─────────────────────────────────────────────────────┐"
    echo "│              共享基础设施连接信息                     │"
    echo "├─────────────────────────────────────────────────────┤"
    printf "│  %-10s %s\n│\n" "MariaDB"  "${DB_ADDR}"
    printf "│  %-10s %s / %s\n│\n" "用户/密码" "${MARIADB_USER}" "${MARIADB_PASSWORD}"
    printf "│  %-10s %s\n│\n" "库名"     "${MARIADB_DATABASE}"
    echo "├─────────────────────────────────────────────────────┤"
    printf "│  %-10s %s\n│\n" "Redis"    "${RE_ADDR}"
    printf "│  %-10s %s\n│\n" "密码"     "${REDIS_PASSWORD}"
    echo "├─────────────────────────────────────────────────────┤"
    printf "│  %-10s %s\n" "凭据文件" "${DIR}/.env"
    echo "└─────────────────────────────────────────────────────┘"
    echo ""
    warn "请将 .env 安全传输到各 WordPress 节点（scp over WireGuard）"
    echo "  scp -i /etc/wireguard/keys/id_ed25519 ${DIR}/.env root@<节点WG_IP>:/srv/wordpress/.env-infra"
}

# ════════════════════════════════════════════════════════════
# add-db [DIR] <DB_NAME> <USER> [PASSWORD]
# ════════════════════════════════════════════════════════════
cmd_add_db() {
    local DIR="${1:-$DEFAULT_DIR}"
    local DB_NAME="${2:?用法: add-db [DIR] <DB名> <用户名> [密码]}"
    local USER="${3:?}"
    local PW="${4:-$(randpw)}"

    _validate_identifier "$DB_NAME" "数据库名"
    _validate_identifier "$USER"    "用户名"

    load_env "$DIR"

    # 修复 #1：WG_IP 缺失时自动探测，不依赖 set -u 崩溃
    local WG_IP
    WG_IP=$(_resolve_wg_ip "$DIR")

    header "新建数据库: ${DB_NAME} / 用户: ${USER}"

    mariadb_exec "$DIR" <<SQL
CREATE DATABASE IF NOT EXISTS \`${DB_NAME}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS '${USER}'@'${WG_IP%.*}.%' IDENTIFIED BY '${PW}';
GRANT ALL PRIVILEGES ON \`${DB_NAME}\`.* TO '${USER}'@'${WG_IP%.*}.%';
CREATE USER IF NOT EXISTS '${USER}'@'172.%' IDENTIFIED BY '${PW}';
GRANT ALL PRIVILEGES ON \`${DB_NAME}\`.* TO '${USER}'@'172.%';
FLUSH PRIVILEGES;
SQL

    log "数据库 ${DB_NAME} 已创建"
    log "用户: ${USER}  密码: ${PW}"
    log "主机: ${WG_IP}:${MARIADB_PORT}"
}

# ════════════════════════════════════════════════════════════
# del-db [DIR] <DB_NAME> <USER>
# ════════════════════════════════════════════════════════════
cmd_del_db() {
    local DIR="${1:-$DEFAULT_DIR}"
    local DB_NAME="${2:?用法: del-db [DIR] <DB名> <用户名>}"
    local USER="${3:?}"

    _validate_identifier "$DB_NAME" "数据库名"
    _validate_identifier "$USER"    "用户名"

    load_env "$DIR"

    # 修复 #2：WG_IP 缺失时自动探测
    local WG_IP
    WG_IP=$(_resolve_wg_ip "$DIR")

    warn "即将删除数据库 ${DB_NAME} 和用户 ${USER}，此操作不可逆！"
    read -rp "确认删除? 输入库名确认: " CONFIRM
    [[ "$CONFIRM" == "$DB_NAME" ]] || { info "已取消"; return; }

    mariadb_exec "$DIR" <<SQL
DROP DATABASE IF EXISTS \`${DB_NAME}\`;
DROP USER IF EXISTS '${USER}'@'${WG_IP%.*}.%';
DROP USER IF EXISTS '${USER}'@'172.%';
FLUSH PRIVILEGES;
SQL
    log "数据库 ${DB_NAME} 和用户 ${USER} 已删除"
}

# ════════════════════════════════════════════════════════════
# list-db [DIR]
# ════════════════════════════════════════════════════════════
cmd_list_db() {
    local DIR="${1:-$DEFAULT_DIR}"
    load_env "$DIR"
    header "数据库列表"
    mariadb_exec "$DIR" -e \
        "SELECT schema_name AS '数据库', \
                default_character_set_name AS '字符集' \
         FROM information_schema.schemata \
         WHERE schema_name NOT IN ('mysql','information_schema','performance_schema','sys');"
    echo ""
    header "用户列表"
    mariadb_exec "$DIR" -e \
        "SELECT user AS '用户', host AS '来源', \
                GROUP_CONCAT(DISTINCT db) AS '可访问库' \
         FROM mysql.db GROUP BY user, host;"
}

# ════════════════════════════════════════════════════════════
# passwd [DIR] <USER> <NEW_PW>
# ════════════════════════════════════════════════════════════
cmd_passwd() {
    local DIR="${1:-$DEFAULT_DIR}"
    local USER="${2:?用法: passwd [DIR] <用户名> <新密码>}"
    local NEW_PW="${3:?}"

    _validate_identifier "$USER" "用户名"

    load_env "$DIR"

    info "正在修改用户 ${USER} 在所有 host 上的密码..."
    local HOSTS
    HOSTS=$(mariadb_exec "$DIR" -sN -e \
        "SELECT host FROM mysql.user WHERE user='${USER}';")

    if [[ -z "$HOSTS" ]]; then
        warn "未找到用户 ${USER}"
        return 1
    fi

    # 修复 #11：循环内避免重复 load_env（mariadb_exec 内部会调用），
    # 此处 load_env 已在上方执行，MARIADB_ROOT_PASSWORD 已在作用域内，
    # mariadb_exec 的内部 load_env 幂等，多次 source 同一文件无副作用，可接受。
    while IFS= read -r HOST; do
        [[ -n "$HOST" ]] || continue
        mariadb_exec "$DIR" -e \
            "ALTER USER '${USER}'@'${HOST}' IDENTIFIED BY '${NEW_PW}';"
        log "已更新 ${USER}@${HOST}"
    done <<< "$HOSTS"

    mariadb_exec "$DIR" -e "FLUSH PRIVILEGES;"
    log "用户 ${USER} 所有 host 密码已更新"
}

# ════════════════════════════════════════════════════════════
# backup [DIR] [DEST]
# ════════════════════════════════════════════════════════════
cmd_backup() {
    local DIR="${1:-$DEFAULT_DIR}"
    local DEST="${2:-${DIR}/backup}"
    local TS
    TS=$(date +%Y%m%d_%H%M%S)

    load_env "$DIR"
    mkdir -p "$DEST"
    header "备份所有数据库 → ${DEST}"

    local DBS
    DBS=$(mariadb_exec "$DIR" -sN -e \
        "SELECT schema_name FROM information_schema.schemata \
         WHERE schema_name NOT IN ('mysql','information_schema','performance_schema','sys');")

    # 修复 #12：用 while read 代替 for，避免库名含空格时 word splitting
    local FAILED=0
    while IFS= read -r DB; do
        [[ -n "$DB" ]] || continue
        local OUT="${DEST}/${DB}_${TS}.sql.gz"
        local TMP="${OUT}.tmp"
        info "备份 ${DB} → ${OUT}"

        # 修复 #6：先写临时文件，成功后原子移动；失败时删除残缺文件
        if compose_run "$DIR" exec -T \
                -e MYSQL_PWD="${MARIADB_ROOT_PASSWORD}" \
                db mariadb-dump \
                    -uroot \
                    --single-transaction \
                    --routines \
                    --triggers \
                    "${DB}" \
            | gzip > "$TMP"; then
            mv "$TMP" "$OUT"
            log "✓ ${DB} ($(du -sh "$OUT" | cut -f1))"
        else
            rm -f "$TMP"
            warn "✗ ${DB} 备份失败，已跳过"
            FAILED=$(( FAILED + 1 ))
        fi
    done <<< "$DBS"

    if [[ $FAILED -gt 0 ]]; then
        warn "备份完成，但有 ${FAILED} 个库失败，请检查上方日志"
    else
        log "备份完成: ${DEST}"
    fi
}

# ════════════════════════════════════════════════════════════
# restore [DIR] <SQL文件>
# ════════════════════════════════════════════════════════════
cmd_restore() {
    local DIR="${1:-$DEFAULT_DIR}"
    local SQL_FILE="${2:?用法: restore [DIR] <SQL文件(.sql 或 .sql.gz)>}"

    load_env "$DIR"
    [[ -f "$SQL_FILE" ]] || error "文件不存在: ${SQL_FILE}"

    # 修复 #5：gz 文件先校验完整性，避免损坏文件静默写入空数据
    if [[ "$SQL_FILE" == *.gz ]]; then
        info "校验压缩文件完整性..."
        gzip -t "$SQL_FILE" || error "gz 文件损坏，请检查备份来源: ${SQL_FILE}"
    fi

    local BASENAME
    BASENAME=$(basename "$SQL_FILE")
    local DB_NAME
    DB_NAME="${BASENAME%.sql.gz}"
    DB_NAME="${DB_NAME%.sql}"
    DB_NAME="${DB_NAME%_[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]_[0-9][0-9][0-9][0-9][0-9][0-9]}"

    if ! [[ "$DB_NAME" =~ ^[A-Za-z0-9_]{1,64}$ ]]; then
        warn "无法从文件名自动推断合法库名（得到: '${DB_NAME}'）"
        read -rp "  请手动输入目标库名: " DB_NAME
        _validate_identifier "$DB_NAME" "数据库名"
    fi

    warn "将恢复到库: ${DB_NAME}"
    read -rp "确认? [y/N] " CONFIRM
    [[ "${CONFIRM,,}" == "y" ]] || { info "已取消"; return; }

    mariadb_exec "$DIR" -e \
        "CREATE DATABASE IF NOT EXISTS \`${DB_NAME}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;"

    if [[ "$SQL_FILE" == *.gz ]]; then
        zcat "$SQL_FILE" | compose_run "$DIR" exec -T \
            -e MYSQL_PWD="${MARIADB_ROOT_PASSWORD}" \
            db mariadb -uroot "${DB_NAME}"
    else
        compose_run "$DIR" exec -T \
            -e MYSQL_PWD="${MARIADB_ROOT_PASSWORD}" \
            db mariadb -uroot "${DB_NAME}" < "$SQL_FILE"
    fi

    log "恢复完成: ${DB_NAME}"
}

# ════════════════════════════════════════════════════════════
# status [DIR]
# ════════════════════════════════════════════════════════════
cmd_status() {
    local DIR="${1:-$DEFAULT_DIR}"
    load_env "$DIR"
    header "服务状态"

    compose_run "$DIR" ps

    echo ""
    header "MariaDB 连通性"
    if compose_run "$DIR" exec -T \
            -e MYSQL_PWD="${MARIADB_ROOT_PASSWORD}" \
            db mariadb-admin -h 127.0.0.1 --skip-ssl -uroot ping --silent 2>/dev/null; then
        log "✓ MariaDB 响应正常"
        mariadb_exec "$DIR" -e "SHOW STATUS LIKE 'Threads_connected';"
    else
        warn "✗ MariaDB 无响应"
    fi

    echo ""
    header "Redis 连通性"
    if compose_run "$DIR" exec -T redis \
            redis-cli -h 127.0.0.1 -a "${REDIS_PASSWORD}" ping 2>/dev/null \
            | grep -q PONG; then
        log "✓ Redis 响应正常"
        compose_run "$DIR" exec -T redis \
            redis-cli -h 127.0.0.1 -a "${REDIS_PASSWORD}" info server 2>/dev/null \
            | grep -E "redis_version|used_memory_human|connected_clients"
    else
        warn "✗ Redis 无响应"
    fi
}

# ════════════════════════════════════════════════════════════
# stop / start / logs
# ════════════════════════════════════════════════════════════
cmd_stop()  { compose_run "${1:-$DEFAULT_DIR}" stop; }
cmd_start() { compose_run "${1:-$DEFAULT_DIR}" start; }
cmd_logs()  {
    local DIR="${1:-$DEFAULT_DIR}"
    local SVC="${2:?用法: logs [DIR] <db|redis>}"
    compose_run "$DIR" logs -f --tail=100 "$SVC"
}

# ════════════════════════════════════════════════════════════
# 交互菜单
# ════════════════════════════════════════════════════════════

_pause() { echo; read -rp "  按 Enter 返回菜单..." _; }

_ask() {
    local PROMPT="$1" VAR="$2" DEFAULT="${3:-}"
    local HINT=""
    [[ -n "$DEFAULT" ]] && HINT=" [默认: ${DEFAULT}]"
    read -rp "  ${PROMPT}${HINT}: " "$VAR"
    if [[ -z "${!VAR}" && -n "$DEFAULT" ]]; then
        printf -v "$VAR" '%s' "$DEFAULT"
    fi
}

_menu_header() {
    clear
    echo
    _c "1;34" "╔══════════════════════════════════════════════════╗"
    _c "1;34" "║      infra-shared  —  共享 MariaDB + Redis       ║"
    _c "1;34" "╚══════════════════════════════════════════════════╝"
    echo
}

menu_main() {
    while true; do
        _menu_header
        echo "  1)  部署共享基础设施（MariaDB + Redis）"
        echo "  2)  查看服务状态"
        echo "  3)  启动服务"
        echo "  4)  停止服务"
        echo "  ─────────────────────────────────────────"
        echo "  5)  数据库管理 ▶"
        echo "  6)  备份 / 恢复 ▶"
        echo "  7)  查看日志"
        echo "  ─────────────────────────────────────────"
        echo "  0)  退出"
        echo
        read -rp "  请选择 [0-7]: " CHOICE
        case "$CHOICE" in
            1) menu_deploy   ;;
            2) menu_status   ;;
            3) menu_start    ;;
            4) menu_stop     ;;
            5) menu_db       ;;
            6) menu_backup   ;;
            7) menu_logs     ;;
            0) echo; info "再见！"; exit 0 ;;
            *) warn "无效选项，请重新输入"; sleep 1 ;;
        esac
    done
}

menu_deploy() {
    _menu_header
    _c "1;33" "  ▶ 部署共享基础设施"
    echo

    local AUTO_IP=""
    if ip link show "${WG_IFACE}" &>/dev/null; then
        AUTO_IP=$(ip addr show "${WG_IFACE}" \
            | awk '/inet /{gsub(/\/.*/, "", $2); print $2; exit}')
    fi

    if [[ -z "$AUTO_IP" ]]; then
        warn "${WG_IFACE} 接口未检测到，请确认 WireGuard 已启动"
        warn "也可手动输入 WireGuard IP 强制继续"
        echo
    fi

    _ask "部署目录" DIR "$DEFAULT_DIR"
    _ask "WireGuard IP" WG_IP "${AUTO_IP}"

    if [[ -z "$WG_IP" ]]; then
        warn "WireGuard IP 不能为空，已取消"
        _pause; return
    fi

    echo
    warn "即将部署到 ${DIR}，WireGuard IP: ${WG_IP}"
    read -rp "  确认继续? [y/N] " C
    [[ "${C,,}" == "y" ]] || { info "已取消"; _pause; return; }
    echo
    cmd_deploy "$DIR" "$WG_IP"
    _pause
}

menu_status() {
    _menu_header
    _ask "部署目录" DIR "$DEFAULT_DIR"
    echo
    cmd_status "$DIR"
    _pause
}

menu_start() {
    _menu_header
    _ask "部署目录" DIR "$DEFAULT_DIR"
    echo
    cmd_start "$DIR"
    _pause
}

menu_stop() {
    _menu_header
    _ask "部署目录" DIR "$DEFAULT_DIR"
    echo
    warn "即将停止 ${DIR} 下的所有服务"
    read -rp "  确认? [y/N] " C
    [[ "${C,,}" == "y" ]] || { info "已取消"; _pause; return; }
    cmd_stop "$DIR"
    _pause
}

menu_logs() {
    _menu_header
    _c "1;33" "  ▶ 查看日志"
    echo
    _ask "部署目录" DIR "$DEFAULT_DIR"
    echo "  1) MariaDB 日志"
    echo "  2) Redis 日志"
    echo
    read -rp "  请选择 [1-2]: " C
    local SVC
    case "$C" in
        1) SVC="db"    ;;
        2) SVC="redis" ;;
        *) warn "无效选项"; _pause; return ;;
    esac
    info "Ctrl+C 退出日志查看"
    echo

    # 修复 #9：trap SIGINT，确保 Ctrl+C 后能正常返回菜单而非退出脚本
    local _OLD_TRAP
    _OLD_TRAP=$(trap -p INT)
    trap 'true' INT
    cmd_logs "$DIR" "$SVC" || true
    eval "${_OLD_TRAP:-trap - INT}"

    _pause
}

menu_db() {
    while true; do
        _menu_header
        _c "1;33" "  ▶ 数据库管理"
        echo
        echo "  1)  新建数据库和用户"
        echo "  2)  删除数据库和用户"
        echo "  3)  列出所有数据库 / 用户"
        echo "  4)  修改用户密码"
        echo "  0)  ← 返回上级"
        echo
        read -rp "  请选择 [0-4]: " C
        case "$C" in
            1) menu_db_add    ;;
            2) menu_db_del    ;;
            3) menu_db_list   ;;
            4) menu_db_passwd ;;
            0) return ;;
            *) warn "无效选项"; sleep 1 ;;
        esac
    done
}

menu_db_add() {
    _menu_header
    _c "1;33" "  ▶ 新建数据库和用户"
    echo
    _ask "部署目录" DIR "$DEFAULT_DIR"
    _ask "数据库名称" DB_NAME ""
    [[ -n "$DB_NAME" ]] || { warn "数据库名不能为空"; _pause; return; }
    _ask "用户名" DB_USER ""
    [[ -n "$DB_USER" ]] || { warn "用户名不能为空"; _pause; return; }
    local AUTO_PW; AUTO_PW=$(randpw)
    _ask "密码" DB_PW "$AUTO_PW"
    echo
    cmd_add_db "$DIR" "$DB_NAME" "$DB_USER" "$DB_PW"
    _pause
}

menu_db_del() {
    _menu_header
    _c "1;33" "  ▶ 删除数据库和用户"
    echo
    _ask "部署目录" DIR "$DEFAULT_DIR"
    info "当前数据库列表："
    cmd_list_db "$DIR" 2>/dev/null || true
    echo
    _ask "要删除的数据库名" DB_NAME ""
    _ask "要删除的用户名"   DB_USER ""
    [[ -n "$DB_NAME" && -n "$DB_USER" ]] || { warn "名称不能为空"; _pause; return; }
    echo
    cmd_del_db "$DIR" "$DB_NAME" "$DB_USER"
    _pause
}

menu_db_list() {
    _menu_header
    _ask "部署目录" DIR "$DEFAULT_DIR"
    echo
    cmd_list_db "$DIR"
    _pause
}

menu_db_passwd() {
    _menu_header
    _c "1;33" "  ▶ 修改用户密码"
    echo
    _ask "部署目录" DIR "$DEFAULT_DIR"
    _ask "用户名"   DB_USER ""
    _ask "新密码（留空自动生成）" NEW_PW "$(randpw)"
    [[ -n "$DB_USER" ]] || { warn "用户名不能为空"; _pause; return; }
    echo
    cmd_passwd "$DIR" "$DB_USER" "$NEW_PW"
    _pause
}

menu_backup() {
    while true; do
        _menu_header
        _c "1;33" "  ▶ 备份 / 恢复"
        echo
        echo "  1)  备份所有数据库"
        echo "  2)  恢复单个库（从 .sql/.sql.gz 文件）"
        echo "  0)  ← 返回上级"
        echo
        read -rp "  请选择 [0-2]: " C
        case "$C" in
            1) menu_backup_run  ;;
            2) menu_restore_run ;;
            0) return ;;
            *) warn "无效选项"; sleep 1 ;;
        esac
    done
}

menu_backup_run() {
    _menu_header
    _c "1;33" "  ▶ 备份所有数据库"
    echo
    _ask "部署目录" DIR "$DEFAULT_DIR"
    _ask "备份输出目录" DEST "${DIR}/backup"
    echo
    cmd_backup "$DIR" "$DEST"
    _pause
}

menu_restore_run() {
    _menu_header
    _c "1;33" "  ▶ 恢复数据库"
    echo
    _ask "部署目录" DIR "$DEFAULT_DIR"
    _ask "SQL 文件路径（.sql 或 .sql.gz）" SQL_FILE ""
    [[ -n "$SQL_FILE" ]] || { warn "路径不能为空"; _pause; return; }
    echo
    cmd_restore "$DIR" "$SQL_FILE"
    _pause
}

# ════════════════════════════════════════════════════════════
# 入口
# ════════════════════════════════════════════════════════════
main() {
    if [[ $# -eq 0 ]]; then
        menu_main
        return
    fi

    local CMD="$1"; shift

    case "$CMD" in
        deploy)   cmd_deploy  "$@" ;;
        add-db)   cmd_add_db  "$@" ;;
        del-db)   cmd_del_db  "$@" ;;
        list-db)  cmd_list_db "$@" ;;
        passwd)   cmd_passwd  "$@" ;;
        backup)   cmd_backup  "$@" ;;
        restore)  cmd_restore "$@" ;;
        status)   cmd_status  "$@" ;;
        stop)     cmd_stop    "$@" ;;
        start)    cmd_start   "$@" ;;
        logs)     cmd_logs    "$@" ;;
        # 修复 #14：仅输出头部用法注释块，不输出内部实现注释
        help|--help|-h)
            sed -n '/^# 用法/,/^# WG_IP/p' "$0" | sed 's/^# \{0,2\}//'
            ;;
        *) error "未知子命令: ${CMD}，执行 help 查看用法" ;;
    esac
}

main "$@"