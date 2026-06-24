#!/usr/bin/env bash
# ============================================================
# wireguard-mesh.sh — WireGuard 纯交互式组网管理面板
# ============================================================
set -euo pipefail

# ── 常量 ────────────────────────────────────────────────────
readonly WG_IFACE="${WG_IFACE:-wg0}"
readonly WG_PORT="${WG_PORT:-51820}"
readonly WG_DIR="/etc/wireguard"
readonly WG_CONF="${WG_DIR}/${WG_IFACE}.conf"
readonly WG_KEY_DIR="${WG_DIR}/keys"
readonly PRIV_KEY_FILE="${WG_KEY_DIR}/privatekey"
readonly PUB_KEY_FILE="${WG_KEY_DIR}/publickey"

# ── 颜色输出 ────────────────────────────────────────────────
if [[ -t 1 ]] && command -v tput &>/dev/null && tput colors &>/dev/null; then
    C_OK="\e[32m"; C_INFO="\e[36m"; C_WARN="\e[33m"; C_ERR="\e[31m"
    C_BOLD="\e[1;34m"; C_RESET="\e[0m"
else
    C_OK=""; C_INFO=""; C_WARN=""; C_ERR=""; C_BOLD=""; C_RESET=""
fi

log()    { printf "${C_OK}[OK]  %s${C_RESET}\n" "$*"; }
info()   { printf "${C_INFO}[..] %s${C_RESET}\n" "$*"; }
warn()   { printf "${C_WARN}[!!] %s${C_RESET}\n" "$*" >&2; }
error()  { printf "${C_ERR}[EE] %s${C_RESET}\n" "$*" >&2; exit 1; }
header() { printf "\n${C_BOLD}══ %s ══${C_RESET}\n" "$*"; }

# ── 前置检查 ────────────────────────────────────────────────
require_root() {
    [[ $EUID -eq 0 ]] || error "需要 root 权限，请用 sudo 执行"
}

require_conf() {
    [[ -f "$WG_CONF" ]] || error "配置文件不存在: $WG_CONF，请先执行初始化"
}

# ── IP 格式验证 ──────────────────────────────────────────────
is_valid_ipv4() {
    local ip="${1%%/*}"
    local IFS='.'
    read -ra octets <<< "$ip"
    [[ ${#octets[@]} -eq 4 ]] || return 1
    for o in "${octets[@]}"; do
        [[ "$o" =~ ^[0-9]+$ ]] || return 1
        (( o >= 0 && o <= 255 ))  || return 1
    done
    return 0
}

is_valid_cidr() {
    local addr="${1%%/*}"
    local mask="${1##*/}"
    is_valid_ipv4 "$addr" || return 1
    [[ "$mask" =~ ^[0-9]+$ ]] && (( mask >= 0 && mask <= 32 )) || return 1
    return 0
}

is_valid_endpoint() {
    local ep="$1"
    [[ "$ep" =~ ^.+:[0-9]{1,5}$ ]] || return 1
    local port="${ep##*:}"
    (( port >= 1 && port <= 65535 )) || return 1
    return 0
}

is_valid_pubkey() {
    [[ "${#1}" -eq 44 ]] && [[ "$1" =~ ^[A-Za-z0-9+/]{43}=$ ]]
}

# ═══════════════════════════════════════════════════════════
# 核心功能函数
# ═══════════════════════════════════════════════════════════

cmd_install() {
    header "安装 WireGuard"
    if command -v wg &>/dev/null; then
        log "WireGuard 已安装: $(wg --version 2>&1 | head -1)"
        return 0
    fi

    if command -v apt-get &>/dev/null; then
        apt-get update -qq
        DEBIAN_FRONTEND=noninteractive apt-get install -y wireguard wireguard-tools iptables
    elif command -v dnf &>/dev/null; then
        dnf install -y wireguard-tools iptables
    elif command -v yum &>/dev/null; then
        yum install -y epel-release
        yum install -y wireguard-tools iptables
    elif command -v pacman &>/dev/null; then
        pacman -Sy --noconfirm wireguard-tools iptables
    else
        error "不支持的包管理器，请手动安装 wireguard-tools 和 iptables"
    fi

    modprobe wireguard 2>/dev/null || warn "wireguard 内核模块加载失败（非特权容器环境可忽略，将使用用户态）"
    log "WireGuard 安装完成"
}

cmd_genkey() {
    header "生成密钥对"
    mkdir -p "$WG_KEY_DIR"
    chmod 700 "$WG_KEY_DIR"

    if [[ -f "$PRIV_KEY_FILE" ]]; then
        warn "密钥已存在，如需重新生成请手动删除"
        return 0
    fi

    local tmp_priv; tmp_priv=$(mktemp "${WG_KEY_DIR}/privatekey.XXXXXX")
    local tmp_pub;  tmp_pub=$(mktemp  "${WG_KEY_DIR}/publickey.XXXXXX")

    wg genkey > "$tmp_priv"
    wg pubkey < "$tmp_priv" > "$tmp_pub"

    chmod 600 "$tmp_priv"
    # [SEC] 公钥权限收紧至 640，避免全局可读
    chmod 640 "$tmp_pub"
    mv "$tmp_priv" "$PRIV_KEY_FILE"
    mv "$tmp_pub"  "$PUB_KEY_FILE"

    log "私钥与公钥生成完毕"
}

cmd_init() {
    local RAW_IP="$1"
    local WG_ADDR
    if [[ "$RAW_IP" == */* ]]; then
        WG_ADDR="$RAW_IP"
    else
        WG_ADDR="${RAW_IP}/24"
    fi

    header "初始化 ${WG_IFACE} (${WG_ADDR})"

    if [[ -f "$WG_CONF" ]]; then
        warn "配置文件已存在: $WG_CONF"
        read -rp "覆盖? [y/N] " CONFIRM
        [[ "${CONFIRM,,}" == "y" ]] || return 0
        _stop_iface_safe
    fi

    # 获取默认物理网卡用于 NAT 转发
    local default_iface
    default_iface=$(ip route show default | awk '/default/ {print $5}' | head -1)
    if [[ -z "$default_iface" ]]; then
        warn "未找到默认出网网卡，路由转发规则可能失效"
        default_iface="eth0"
    fi

    mkdir -p "$WG_DIR"
    chmod 700 "$WG_DIR"
    install -m 600 /dev/null "$WG_CONF"

    # [SEC] ip_forward 持久化写入 sysctl，重启后仍生效
    echo "net.ipv4.ip_forward = 1" > /etc/sysctl.d/99-wireguard.conf
    sysctl -p /etc/sysctl.d/99-wireguard.conf -q
    info "ip_forward 已持久化至 /etc/sysctl.d/99-wireguard.conf"

    # [SEC] iptables 规则改用幂等写法（-C 检测存在性，避免重复追加）
    # PostUp/PostDown 中不再执行 sysctl（已持久化），专注防火墙规则
    cat > "$WG_CONF" <<EOF
[Interface]
Address = ${WG_ADDR}
PrivateKey = $(cat "$PRIV_KEY_FILE")
ListenPort = ${WG_PORT}
PostUp   = iptables -C FORWARD -i %i -j ACCEPT 2>/dev/null || iptables -A FORWARD -i %i -j ACCEPT
PostUp   = iptables -C FORWARD -o %i -j ACCEPT 2>/dev/null || iptables -A FORWARD -o %i -j ACCEPT
PostUp   = iptables -C POSTROUTING -t nat -o ${default_iface} -j MASQUERADE 2>/dev/null || iptables -t nat -A POSTROUTING -o ${default_iface} -j MASQUERADE
PostDown = iptables -D FORWARD -i %i -j ACCEPT 2>/dev/null || true
PostDown = iptables -D FORWARD -o %i -j ACCEPT 2>/dev/null || true
PostDown = iptables -t nat -D POSTROUTING -o ${default_iface} -j MASQUERADE 2>/dev/null || true
EOF

    log "配置已生成，iptables 规则已幂等化 (出站网卡: ${default_iface})"
}

cmd_add_peer() {
    require_conf
    local PUB_KEY="$1" ALLOWED_IPS="$2" ENDPOINT="${3:-}"

    header "添加 Peer: ${ALLOWED_IPS}"

    # [SEC] 输入校验
    if ! is_valid_pubkey "$PUB_KEY"; then
        warn "公钥格式不合法（需 44 位 Base64）"
        return 1
    fi
    if ! is_valid_cidr "$ALLOWED_IPS" && ! is_valid_ipv4 "$ALLOWED_IPS"; then
        warn "AllowedIPs 格式不合法: $ALLOWED_IPS"
        return 1
    fi
    if [[ -n "$ENDPOINT" ]] && ! is_valid_endpoint "$ENDPOINT"; then
        warn "Endpoint 格式不合法: $ENDPOINT（应为 host:port）"
        return 1
    fi

    # [SEC] 全路由警告：AllowedIPs = 0.0.0.0/0 会将所有流量导入隧道
    if [[ "$ALLOWED_IPS" == "0.0.0.0/0" || "$ALLOWED_IPS" == "::/0" || "$ALLOWED_IPS" == "0.0.0.0/0,::/0" ]]; then
        warn "AllowedIPs 设置为全路由 (${ALLOWED_IPS})，该 Peer 将接管本机所有出站流量！"
        read -r -t 30 -p "  确认继续? [y/N] " _fullroute_confirm || { echo; warn "输入超时，已取消"; return 1; }
        [[ "${_fullroute_confirm,,}" == "y" ]] || { info "已取消"; return 0; }
    fi

    if grep -qE "^\s*PublicKey\s*=\s*${PUB_KEY}\s*$" "$WG_CONF"; then
        warn "该 Peer 公钥已存在"
        return 0
    fi

    _backup_conf
    {
        printf '\n[Peer]\n'
        printf 'PublicKey = %s\n' "$PUB_KEY"
        printf 'AllowedIPs = %s\n' "$ALLOWED_IPS"
        if [[ -n "$ENDPOINT" ]]; then
            printf 'Endpoint = %s\n' "$ENDPOINT"
            printf 'PersistentKeepalive = 25\n'
        fi
    } >> "$WG_CONF"

    log "Peer 已追加"
    if _iface_is_up; then
        local -a args=(set "${WG_IFACE}" peer "${PUB_KEY}" allowed-ips "${ALLOWED_IPS}")
        [[ -n "$ENDPOINT" ]] && args+=(endpoint "${ENDPOINT}" persistent-keepalive 25)
        wg "${args[@]}" && log "热更新成功"
    fi
}

cmd_remove_peer() {
    require_conf
    local PUB_KEY="$1"

    header "移除 Peer"
    if ! grep -qE "^\s*PublicKey\s*=\s*${PUB_KEY}\s*$" "$WG_CONF"; then
        warn "未找到该 Peer"
        return 1
    fi

    _backup_conf

    # 使用 awk 精确移除指定的 [Peer] 块
    awk -v target="$PUB_KEY" '
        BEGIN { in_peer = 0; block = ""; found = 0 }
        /^\[Peer\]/ {
            if (in_peer && !found) print block;
            in_peer = 1; block = $0 "\n"; found = 0;
            next
        }
        /^\[Interface\]/ {
            if (in_peer && !found) print block;
            in_peer = 0; print;
            next
        }
        in_peer {
            block = block $0 "\n"
            if ($0 ~ "^[[:space:]]*PublicKey[[:space:]]*=[[:space:]]*" target) {
                found = 1
            }
        }
        !in_peer { print }
        END {
            if (in_peer && !found) print block;
        }
    ' "$WG_CONF" > "${WG_CONF}.tmp" && mv "${WG_CONF}.tmp" "$WG_CONF"

    log "Peer 已从配置移除"

    if _iface_is_up; then
        wg set "${WG_IFACE}" peer "$PUB_KEY" remove 2>/dev/null && log "热移除成功"
    fi
}

cmd_up() {
    require_conf
    header "启动 ${WG_IFACE}"

    _stop_iface_safe

    # 兼容 systemd 与非 systemd 环境
    if pidof systemd &>/dev/null || [[ -d /run/systemd/system ]]; then
        systemctl enable --now "wg-quick@${WG_IFACE}"
    else
        wg-quick up "$WG_CONF"
    fi

    if _iface_is_up; then
        log "${WG_IFACE} 已成功启动"
    else
        error "启动失败，请检查配置或内核支持"
    fi
}

cmd_down() {
    header "停止 ${WG_IFACE}"
    _stop_iface_safe
    log "${WG_IFACE} 已停止"
}

# ═══════════════════════════════════════════════════════════
# 辅助工具函数
# ═══════════════════════════════════════════════════════════

_iface_is_up() {
    ip link show "${WG_IFACE}" &>/dev/null
}

_stop_iface_safe() {
    if pidof systemd &>/dev/null || [[ -d /run/systemd/system ]]; then
        systemctl disable --now "wg-quick@${WG_IFACE}" 2>/dev/null || true
        systemctl reset-failed "wg-quick@${WG_IFACE}" 2>/dev/null || true
    fi
    if ip link show "${WG_IFACE}" &>/dev/null; then
        wg-quick down "${WG_IFACE}" 2>/dev/null || ip link delete "${WG_IFACE}" 2>/dev/null || true
    fi
}

_backup_conf() {
    local bak="${WG_CONF}.bak.$(date +%Y%m%d_%H%M%S)"
    cp "$WG_CONF" "$bak"
    # [SEC] 备份文件显式设为 600，与主配置保持一致
    chmod 600 "$bak"
    info "配置已备份: $bak"
}

# [SEC] _ask 加入 read 超时（120s），防止长时间挂起
_ask() {
    local prompt="$1" varname="$2" default="${3:-}" val hint=""
    [[ -n "$default" ]] && hint=" [默认: ${default}]"
    if ! read -r -t 120 -p "  ${prompt}${hint}: " val; then
        echo
        error "输入超时（120s），已退出"
    fi
    printf -v "$varname" '%s' "${val:-$default}"
}

_pause() { echo; read -r -t 300 -p "  按 Enter 返回主菜单..." _ || true; }

# ═══════════════════════════════════════════════════════════
# 交互菜单逻辑
# ═══════════════════════════════════════════════════════════

_menu_header() {
    clear
    printf "\n${C_BOLD}"
    echo "  ╔══════════════════════════════════════════════════╗"
    echo "  ║       WireGuard Mesh Panel - 交互式管控台        ║"
    echo "  ╚══════════════════════════════════════════════════╝"
    printf "${C_RESET}\n"

    local key_disp conf_disp wg_disp
    [[ -f "$PUB_KEY_FILE" ]] && key_disp="$(cut -c1-16 "$PUB_KEY_FILE")..." || key_disp="（未生成）"
    [[ -f "$WG_CONF" ]] && conf_disp="${WG_CONF} ($(grep -c '^\[Peer\]' "$WG_CONF" 2>/dev/null || echo 0) peers)" || conf_disp="（未初始化）"
    _iface_is_up && wg_disp="${C_OK}运行中 ✓${C_RESET}" || wg_disp="${C_WARN}已停止${C_RESET}"

    printf "  本机公钥: ${C_INFO}%s${C_RESET}\n" "$key_disp"
    printf "  配置文件: ${C_INFO}%s${C_RESET}\n" "$conf_disp"
    printf "  接口状态: %b\n\n" "$wg_disp"
}

_run() {
    local title="$1"; shift
    _menu_header
    printf "  ${C_WARN}▶ %s${C_RESET}\n\n" "$title"
    "$@" || true
    _pause
}

menu_main() {
    require_root
    while true; do
        _menu_header
        echo "  [ 核心部署 ]"
        echo "  1. 安装 WireGuard 组件"
        echo "  2. 生成本机通信密钥对"
        echo "  3. 查看本机公钥 (提供给对端)"
        echo "  4. 初始化本机网络配置"
        echo "  "
        echo "  [ 节点管控 ]"
        echo "  5. 添加对端节点 (Add Peer)"
        echo "  6. 移除对端节点 (Remove Peer)"
        echo "  7. 列出所有节点"
        echo "  "
        echo "  [ 启停控制 ]"
        echo "  8. 启动 WireGuard"
        echo "  9. 停止 WireGuard"
        echo "  10. 测试连通性及状态"
        echo "  "
        echo "  0. 退出面板"
        echo
        read -r -t 300 -p "  请输入序号选择: " CHOICE || { echo; continue; }
        case "$CHOICE" in
            1) _run "安装 WireGuard" cmd_install ;;
            2) _run "生成密钥对" cmd_genkey ;;
            3)
                _menu_header
                [[ -f "$PUB_KEY_FILE" ]] && echo "  公钥: $(cat "$PUB_KEY_FILE")" || warn "密钥未生成"
                _pause
                ;;
            4)
                _menu_header
                _ask "请输入本机 WG IP (如 10.10.0.1/24)" MY_IP
                if is_valid_cidr "$MY_IP" || is_valid_ipv4 "$MY_IP"; then
                    cmd_init "$MY_IP"
                else
                    warn "IP 格式错误: $MY_IP"
                fi
                _pause
                ;;
            5)
                _menu_header
                _ask "对端公钥 (44字符 Base64)" P_PK
                _ask "对端内网 IP/CIDR (如 10.10.0.2/32)" P_IP
                _ask "对端公网 Endpoint (如 1.2.3.4:51820，无则回车跳过)" P_EP
                if [[ -n "$P_PK" && -n "$P_IP" ]]; then
                    cmd_add_peer "$P_PK" "$P_IP" "$P_EP"
                else
                    warn "公钥和 IP 不能为空"
                fi
                _pause
                ;;
            6)
                _menu_header
                _ask "要移除的对端公钥" RM_PK
                [[ -n "$RM_PK" ]] && cmd_remove_peer "$RM_PK"
                _pause
                ;;
            7)  _run "节点列表" wg show "${WG_IFACE}" ;;
            8)  _run "启动接口" cmd_up ;;
            9)  _run "停止接口" cmd_down ;;
            10) _run "网络状态" wg show "${WG_IFACE}" ;;
            0)  echo; exit 0 ;;
            *)  ;;
        esac
    done
}

# 仅保留进入菜单的入口
menu_main
