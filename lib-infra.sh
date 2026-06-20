#!/usr/bin/env bash
# ============================================================
# lib-infra.sh — 公共函数库，供 infra-mariadb.sh / infra-redis.sh source
# 不可直接执行
# ============================================================
[[ "${BASH_SOURCE[0]}" != "${0}" ]] || { echo "lib-infra.sh 不可直接执行" >&2; exit 1; }

# ── 默认值 ──────────────────────────────────────────────────
export WG_IFACE="${WG_IFACE:-wg0}"
export MARIADB_PORT="${MARIADB_PORT:-3306}"
export REDIS_PORT="${REDIS_PORT:-6379}"
export MARIADB_IMAGE="${MARIADB_IMAGE:-mariadb:11}"
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
