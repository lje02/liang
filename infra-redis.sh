#!/usr/bin/env bash
# ============================================================
# infra-redis.sh — 独立 Redis（仅监听 WireGuard 网口）
#
# 用法:
#   infra-redis.sh [DIR] [WG_IP]   # 交互菜单
#   infra-redis.sh deploy  [DIR] [WG_IP]
#   infra-redis.sh status  [DIR]
#   infra-redis.sh start   [DIR]
#   infra-redis.sh stop    [DIR]
#   infra-redis.sh logs    [DIR]
#   infra-redis.sh flush   [DIR]    # 清空所有缓存
#
# WG_IP 默认读取 wg0 接口当前地址，也可显式传入
# ============================================================
set -euo pipefail
export LANG=en_US.UTF-8
export LC_ALL=en_US.UTF-8


# ════════════════════════════════════════════════════════════
# 公共函数（内联）
# ════════════════════════════════════════════════════════════
# ── 默认值 ──────────────────────────────────────────────────
export WG_IFACE="${WG_IFACE:-wg0}"
export REDIS_PORT="${REDIS_PORT:-6379}"
export REDIS_IMAGE="${REDIS_IMAGE:-redis:7-alpine}"

# ── 颜色输出 ────────────────────────────────────────────────
_c()     { printf "\033[%sm%s\033[0m\n" "${1}" "${2}"; }
log()    { _c "32"   "[OK]  $*"; }
info()   { _c "36"   "[..] $*"; }
warn()   { _c "33"   "[!!] $*"; }
error()  { _c "31"   "[EE] $*"; exit 1; }
header() { echo; _c "1;34" "══ $* ══"; }

# ── 随机密码 ────────────────────────────────────────────────
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

# ── 读取 .env ───────────────────────────────────────────────
load_env() {
    local DIR="$1"
    [[ -f "$DIR/.env" ]] || error ".env 不存在: $DIR/.env"
    # shellcheck disable=SC1090
    source "$DIR/.env"
}

# ── compose 快捷执行 ────────────────────────────────────────
compose_run() {
    local DIR="$1"; shift
    docker compose -f "$DIR/docker-compose.yml" --env-file "$DIR/.env" "$@"
}

# ── 校验标识符 ───────────────────────────────────────────────
_validate_identifier() {
    local VALUE="$1" LABEL="$2"
    [[ "$VALUE" =~ ^[A-Za-z0-9_]{1,64}$ ]] \
        || error "${LABEL} 只能包含字母、数字、下划线，长度 1-64，实际值: '${VALUE}'"
}

# ── 从 .env 解析 WG_IP，若缺失则探测接口 ───────────────────
_resolve_wg_ip() {
    local DIR="$1"
    local IP="${WG_IP:-}"
    if [[ -z "$IP" ]]; then
        warn ".env 中未找到 WG_IP，尝试从 ${WG_IFACE} 接口获取"
        IP=$(get_wg_ip)
    fi
    echo "$IP"
}

# ── 交互辅助 ────────────────────────────────────────────────
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
    local TITLE="$1"
    clear
    echo
    _c "1;34" "╔══════════════════════════════════════════════════╗"
    _c "1;34" "║  ${TITLE}"
    _c "1;34" "╚══════════════════════════════════════════════════╝"
    echo
}

DEFAULT_DIR="${BASE_DIR:-/srv}/infra-redis"

# ════════════════════════════════════════════════════════════
# Redis 内部工具函数
# ════════════════════════════════════════════════════════════

# 调用方须已 load_env，REDIS_PASSWORD 在作用域内
redis_cli_exec() {
    local DIR="$1"; shift
    compose_run "$DIR" exec -T redis \
        redis-cli -h 127.0.0.1 -a "${REDIS_PASSWORD}" "$@" 2>/dev/null
}

wait_redis_ready() {
    local DIR="$1" RETRIES="${2:-20}"
    info "等待 Redis 就绪..."
    while ! compose_run "$DIR" exec -T redis \
            redis-cli -h 127.0.0.1 -a "${REDIS_PASSWORD}" \
            ping 2>/dev/null | grep -q PONG; do
        sleep 2
        (( RETRIES-- ))
        [[ $RETRIES -gt 0 ]] || error "Redis 启动超时"
    done
    log "Redis 就绪"
}

_print_credentials() {
    local DIR="$1"
    load_env "$DIR"
    echo ""
    echo "┌─────────────────────────────────────────────────────┐"
    echo "│                 Redis 连接信息                       │"
    echo "├─────────────────────────────────────────────────────┤"
    printf "│  %-10s %s\n│\n" "地址"     "${WG_IP}:${REDIS_PORT}"
    printf "│  %-10s %s\n│\n" "密码"     "${REDIS_PASSWORD}"
    printf "│  %-10s %s\n" "凭据文件" "${DIR}/.env"
    echo "└─────────────────────────────────────────────────────┘"
    echo ""
    warn "请将 .env 安全传输到各 WordPress 节点"
    echo "  scp -i /etc/wireguard/keys/id_ed25519 ${DIR}/.env root@<节点WG_IP>:/srv/wordpress/.env-redis"
}

# ════════════════════════════════════════════════════════════
# deploy [DIR] [WG_IP]
# ════════════════════════════════════════════════════════════
cmd_deploy() {
    local DIR="${1:-$DEFAULT_DIR}"
    local WG_IP="${2:-$(get_wg_ip)}"

    header "部署 Redis → ${DIR}  (监听 ${WG_IP})"
    [[ $EUID -eq 0 ]] || error "需要 root 权限"
    ip link show "${WG_IFACE}" &>/dev/null || \
        error "${WG_IFACE} 接口不存在，请先启动 WireGuard"

    mkdir -p "${DIR}"/{redis,redis-conf}

    if [[ ! -f "${DIR}/.env" ]]; then
        local REDIS_PW; REDIS_PW=$(randpw)
        cat > "${DIR}/.env" <<EOF
REDIS_PASSWORD=${REDIS_PW}
WG_IP=${WG_IP}
EOF
        chmod 600 "${DIR}/.env"
        log ".env 已生成: ${DIR}/.env"
    else
        warn ".env 已存在，跳过生成密码"
        sed -i "s|^WG_IP=.*|WG_IP=${WG_IP}|" "${DIR}/.env"
    fi

    load_env "${DIR}"

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

    cat > "${DIR}/docker-compose.yml" <<YAML
services:
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

    compose_run "${DIR}" up -d 2>&1 || error "docker compose up 失败"
    wait_redis_ready "${DIR}"

    echo ""
    compose_run "${DIR}" ps
    log "Redis 部署完成"
    _print_credentials "${DIR}"
}

# ════════════════════════════════════════════════════════════
# status [DIR]
# ════════════════════════════════════════════════════════════
cmd_status() {
    local DIR="${1:-$DEFAULT_DIR}"
    load_env "$DIR"
    header "Redis 状态"
    compose_run "$DIR" ps
    echo ""
    if redis_cli_exec "$DIR" ping | grep -q PONG; then
        log "✓ Redis 响应正常"
        redis_cli_exec "$DIR" info server \
            | grep -E "redis_version|used_memory_human|connected_clients|uptime_in_days"
        echo ""
        redis_cli_exec "$DIR" info keyspace || true
    else
        warn "✗ Redis 无响应"
    fi
}

# ════════════════════════════════════════════════════════════
# flush [DIR]  — 清空所有缓存键
# ════════════════════════════════════════════════════════════
cmd_flush() {
    local DIR="${1:-$DEFAULT_DIR}"
    load_env "$DIR"
    warn "即将执行 FLUSHALL，清空 Redis 所有数据！"
    read -rp "  确认? [y/N] " C
    [[ "${C,,}" == "y" ]] || { info "已取消"; return; }
    redis_cli_exec "$DIR" FLUSHALL
    log "Redis 已清空"
}

cmd_stop()  { load_env "${1:-$DEFAULT_DIR}"; compose_run "${1:-$DEFAULT_DIR}" stop; }
cmd_start() { load_env "${1:-$DEFAULT_DIR}"; compose_run "${1:-$DEFAULT_DIR}" start; }
cmd_logs()  {
    local DIR="${1:-$DEFAULT_DIR}"
    compose_run "$DIR" logs -f --tail=100 redis
}

# ════════════════════════════════════════════════════════════
# 交互菜单
# ════════════════════════════════════════════════════════════
menu_main() {
    while true; do
        _menu_header "infra-redis.sh  共享 Redis                  "
        echo "  1)  部署 Redis"
        echo "  2)  查看服务状态"
        echo "  3)  启动服务"
        echo "  4)  停止服务"
        echo "  5)  查看日志"
        echo "  6)  清空所有缓存（FLUSHALL）"
        echo "  ─────────────────────────────────────────"
        echo "  0)  退出"
        echo
        read -rp "  请选择 [0-6]: " CHOICE
        case "$CHOICE" in
            1) menu_deploy ;;
            2) menu_status ;;
            3) menu_start  ;;
            4) menu_stop   ;;
            5) menu_logs   ;;
            6) menu_flush  ;;
            0) echo; info "再见！"; exit 0 ;;
            *) warn "无效选项"; sleep 1 ;;
        esac
    done
}

menu_deploy() {
    _menu_header "▶ 部署 Redis                                    "
    local AUTO_IP=""
    if ip link show "${WG_IFACE}" &>/dev/null; then
        AUTO_IP=$(ip addr show "${WG_IFACE}" \
            | awk '/inet /{gsub(/\/.*/, "", $2); print $2; exit}')
    fi
    [[ -z "$AUTO_IP" ]] && warn "${WG_IFACE} 未检测到，请确认 WireGuard 已启动"

    _ask "部署目录" DIR "$DEFAULT_DIR"
    _ask "WireGuard IP" WG_IP "${AUTO_IP}"
    [[ -n "$WG_IP" ]] || { warn "WireGuard IP 不能为空"; _pause; return; }

    warn "即将部署到 ${DIR}，WireGuard IP: ${WG_IP}"
    read -rp "  确认继续? [y/N] " C
    [[ "${C,,}" == "y" ]] || { info "已取消"; _pause; return; }
    cmd_deploy "$DIR" "$WG_IP"
    _pause
}

menu_status() {
    _menu_header "▶ 服务状态                                      "
    _ask "部署目录" DIR "$DEFAULT_DIR"
    cmd_status "$DIR"; _pause
}

menu_start() {
    _menu_header "▶ 启动服务                                      "
    _ask "部署目录" DIR "$DEFAULT_DIR"
    cmd_start "$DIR"; _pause
}

menu_stop() {
    _menu_header "▶ 停止服务                                      "
    _ask "部署目录" DIR "$DEFAULT_DIR"
    warn "即将停止 ${DIR} 下的服务"
    read -rp "  确认? [y/N] " C
    [[ "${C,,}" == "y" ]] || { info "已取消"; _pause; return; }
    cmd_stop "$DIR"; _pause
}

menu_logs() {
    _menu_header "▶ 查看日志                                      "
    _ask "部署目录" DIR "$DEFAULT_DIR"
    info "Ctrl+C 退出日志查看"
    local _OLD_TRAP; _OLD_TRAP=$(trap -p INT)
    trap 'true' INT
    cmd_logs "$DIR" || true
    eval "${_OLD_TRAP:-trap - INT}"
    _pause
}

menu_flush() {
    _menu_header "▶ 清空缓存                                      "
    _ask "部署目录" DIR "$DEFAULT_DIR"
    cmd_flush "$DIR"; _pause
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
        deploy)  cmd_deploy "$@" ;;
        status)  cmd_status "$@" ;;
        start)   cmd_start  "$@" ;;
        stop)    cmd_stop   "$@" ;;
        logs)    cmd_logs   "$@" ;;
        flush)   cmd_flush  "$@" ;;
        help|--help|-h)
            sed -n '/^# 用法/,/^# WG_IP/p' "$0" | sed 's/^# \{0,2\}//'
            ;;
        *) error "未知子命令: ${CMD}，执行 help 查看用法" ;;
    esac
}

main "$@"
