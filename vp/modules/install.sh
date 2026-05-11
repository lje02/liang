#!/bin/bash

# ========================================================
# sing-box 综合管理脚本 (ssb)
# ========================================================

RED='\033[1;31m'
GREEN='\033[1;32m'
YELLOW='\033[1;33m'
CYAN='\033[1;36m'
BLUE='\033[1;34m'
PLAIN='\033[0m'

CONFIG_FILE="/etc/sing-box/config.json"
LINK_DIR="/etc/sing-box/links"
CERT_DIR="/etc/sing-box/certs"
BACKUP_DIR="/root/singbox_backup"
SB_BIN=$(command -v sing-box || echo "/usr/local/bin/sing-box")
UPDATE_URL="https://raw.githubusercontent.com/lje02/sing/main/install.sh"

[[ $EUID -ne 0 ]] && echo -e "${RED}错误: 必须使用 root 运行！${PLAIN}" && exit 1

# --- 辅助工具 ---
pause() {
    echo ""
    read -p "操作完成，按回车键继续..."
}

# 原子化写入配置并进行语法检查
save_and_restart() {
    if [[ ! -f tmp.json ]]; then
        echo -e "${RED}错误: 临时配置文件生成失败。${PLAIN}"
        return 1
    fi

    if $SB_BIN check -c tmp.json > /dev/null 2>&1; then
        mv tmp.json "$CONFIG_FILE"
        systemctl restart sing-box
        return 0
    else
        echo -e "${RED}✘ 配置语法检查失败，请检查参数设置。旧配置已保留。${PLAIN}"
        rm -f tmp.json
        return 1
    fi
}

# 辅助函数：只在指定的 CERT_DIR 目录下扫描
find_certs() {
    local domain=$1
    local search_dir="$CERT_DIR/$domain"
    
    CERT_PATH=""; KEY_PATH=""
    
    if [[ -d "$search_dir" ]]; then
        # 常见证书文件名列表（按优先级排序）
        local c_names=("server.crt" "fullchain.cer" "fullchain.pem" "$domain.cer" "cert.pem")
        local k_names=("server.key" "$domain.key" "privkey.pem" "cert.key")

        for f in "${c_names[@]}"; do [[ -f "$search_dir/$f" ]] && CERT_PATH="$search_dir/$f" && break; done
        for f in "${k_names[@]}"; do [[ -f "$search_dir/$f" ]] && KEY_PATH="$search_dir/$f" && break; done
    fi
}

init_config() {
    mkdir -p /etc/sing-box "$LINK_DIR" "$CERT_DIR"
    if [ ! -f "$CONFIG_FILE" ] || [ ! -s "$CONFIG_FILE" ]; then
        echo '{"log":{"level":"info"},"inbounds":[],"outbounds":[{"type":"direct","tag":"direct"}],"route":{"rules":[]}}' > "$CONFIG_FILE"
    fi
}

get_ip() {
    local mode=${1:-"all"} # 参数可选: all, 4, 6
    local ip4 ip6

    # 同时探测
    ip4=$(curl -s4 --connect-timeout 3 icanhazip.com || curl -s4 --connect-timeout 3 ifconfig.me)
    ip6=$(curl -s6 --connect-timeout 3 icanhazip.com || curl -s6 --connect-timeout 3 ifconfig.me)

    case $mode in
        4) echo "$ip4" ;;
        6) [[ -n "$ip6" ]] && echo "[$ip6]" ;;
        "all")
            # 逻辑：优先返回 v4，如果没有 v4 则返回带括号的 v6
            if [[ -n "$ip4" ]]; then
                echo "$ip4"
            elif [[ -n "$ip6" ]]; then
                echo "[$ip6]"
            else
                echo "127.0.0.1"
            fi
            ;;
    esac
}

show_status() {
    if systemctl is-active --quiet sing-box; then
        echo -e "sing-box 状态: ${GREEN}[运行中]${PLAIN}"
    else
        echo -e "sing-box 状态: ${RED}[未运行/已停止]${PLAIN}"
    fi
}

# --- 功能模块 ---

apply_cert() {
    echo -e "${YELLOW}--- ACME 域名证书申请 ---${PLAIN}"
    read -p "请输入解析到本机的域名: " domain
    [[ -z "$domain" ]] && echo -e "${RED}域名不能为空${PLAIN}" && pause && return

    apt update && apt install -y socat cron uuid-runtime
    if [ ! -f ~/.acme.sh/acme.sh ]; then
        curl https://get.acme.sh | sh -s email=admin@$domain
        source ~/.bashrc
    fi

    echo -e "${YELLOW}正在尝试申请证书...${PLAIN}"
    systemctl stop sing-box 2>/dev/null
    ~/.acme.sh/acme.sh --issue -d "$domain" --standalone --server letsencrypt
    
    if [ $? -eq 0 ]; then
        local target_dir="$CERT_DIR/$domain"
        mkdir -p "$target_dir"
        ~/.acme.sh/acme.sh --install-cert -d "$domain" \
            --key-file "$target_dir/server.key" \
            --fullchain-file "$target_dir/server.crt"
        echo -e "${GREEN}✔ 证书安装成功！路径: $target_dir${PLAIN}"
    else
        echo -e "${RED}✘ 申请失败，请确认 80 端口未被占用且域名解析正确。${PLAIN}"
    fi
    systemctl start sing-box 2>/dev/null
    pause
}

auto_backup() {
    mkdir -p "$BACKUP_DIR"
    local TIME=$(date +%Y%m%d_%H%M%S)
    local B_NAME="auto_bak_before_update_$TIME.tar.gz"
    
    mkdir -p "/tmp/sb_auto_bak"
    [[ -f "/usr/local/bin/sing-box" ]] && cp "/usr/local/bin/sing-box" "/tmp/sb_auto_bak/"
    [[ -d "/etc/sing-box" ]] && cp -r /etc/sing-box/* "/tmp/sb_auto_bak/"
    
    tar -czf "$BACKUP_DIR/$B_NAME" -C "/tmp/sb_auto_bak" . >/dev/null 2>&1
    rm -rf "/tmp/sb_auto_bak"
    echo -e "${YELLOW}[自动快照] 更新前已备份至: $B_NAME${PLAIN}"
}

backup_restore() {
    clear
    echo -e "${YELLOW}--- 备份与还原 ---${PLAIN}"
    echo "1. 立即备份 (内核 + 配置)"
    echo "2. 还原备份"
    echo "0. 返回"
    read -p "选择: " br_choice
    [[ "$br_choice" == "0" ]] && return
    
    mkdir -p "$BACKUP_DIR"
    if [[ "$br_choice" == "1" ]]; then
        local TIME=$(date +%Y%m%d_%H%M%S)
        mkdir -p "/tmp/sb_bak"
        [[ -f "/usr/local/bin/sing-box" ]] && cp /usr/local/bin/sing-box "/tmp/sb_bak/"
        [[ -d "/etc/sing-box" ]] && cp -r /etc/sing-box "/tmp/sb_bak/"
        tar -czf "$BACKUP_DIR/singbox_full_$TIME.tar.gz" -C "/tmp/sb_bak" .
        rm -rf "/tmp/sb_bak"
        echo -e "${GREEN}备份完成: singbox_full_$TIME.tar.gz${PLAIN}"
    elif [[ "$br_choice" == "2" ]]; then
        local files=($(ls "$BACKUP_DIR" | grep ".tar.gz"))
        if [ ${#files[@]} -eq 0 ]; then
            echo -e "${RED}没有找到备份文件${PLAIN}"
        else
            ls "$BACKUP_DIR" | grep ".tar.gz" | cat -n
            read -p "选择要还原的序号: " r_idx
            local R_FILE=${files[$((r_idx-1))]}
            if [[ -n "$R_FILE" ]]; then
                systemctl stop sing-box
                tar -xzf "$BACKUP_DIR/$R_FILE" -C /tmp/
                cp /tmp/sing-box /usr/local/bin/sing-box
                cp -r /tmp/sing-box/* /etc/sing-box/
                systemctl restart sing-box
                echo -e "${GREEN}备份 $R_FILE 还原成功${PLAIN}"
            fi
        fi
    fi
    pause
}

install_base() {
    echo -e "${GREEN}>>> 正在安装依赖并检测架构...${PLAIN}"

    # ---------- 安装依赖（兼容 apt/yum，jq） ----------
    if command -v apt &>/dev/null; then
        apt update -y && apt install -y curl jq tar wget uuid-runtime
    elif command -v yum &>/dev/null; then
        yum install -y curl jq tar wget util-linux
    else
        echo -e "${RED}不支持的包管理器，请手动安装依赖${PLAIN}"
        pause && return
    fi

    # ---------- 架构检测 ----------
    local arch=""
    case "$(uname -m)" in
        x86_64) arch="amd64" ;;
        aarch64) arch="arm64" ;;
        armv7l) arch="armv7" ;;
        *) echo -e "${RED}不支持的架构: $(uname -m)${PLAIN}"; pause; return ;;
    esac

    # ---------- 获取最新版本（jq） ----------
    echo -e "${CYAN}获取 sing-box 最新版本...${PLAIN}"
    TAG=$(curl -s "https://api.github.com/repos/SagerNet/sing-box/releases/latest" | jq -r .tag_name)
    if [[ -z "$TAG" ]]; then
        echo -e "${RED}无法获取最新版本号，请检查网络或 GitHub API 限制${PLAIN}"
        pause && return
    fi
    echo -e "${CYAN}检测到架构: $arch, 即将下载版本: $TAG${PLAIN}"

    # ---------- 在安全临时目录中下载并解压 ----------
    local TMP_DIR=$(mktemp -d)
    local url="https://github.com/SagerNet/sing-box/releases/download/${TAG}/sing-box-${TAG#v}-linux-${arch}.tar.gz"

    wget -q --show-progress -O "$TMP_DIR/sing-box.tar.gz" "$url" || {
        echo -e "${RED}下载失败，请检查版本或网络${PLAIN}"
        rm -rf "$TMP_DIR"
        pause && return
    }

    tar -xzf "$TMP_DIR/sing-box.tar.gz" -C "$TMP_DIR" || {
        echo -e "${RED}解压失败${PLAIN}"
        rm -rf "$TMP_DIR"
        pause && return
    }

    # 精确查找可执行文件，避免目录名变化导致 mv 失败
    local BIN=$(find "$TMP_DIR" -type f -name "sing-box" -executable | head -1)
    if [[ -z "$BIN" ]]; then
        echo -e "${RED}未找到 sing-box 可执行文件${PLAIN}"
        rm -rf "$TMP_DIR"
        pause && return
    fi

    cp "$BIN" /usr/local/bin/sing-box
    chmod +x /usr/local/bin/sing-box
    rm -rf "$TMP_DIR"          # 用完即删，不留垃圾

    # ---------- 创建 systemd 服务 ----------
    # 如果外部没定义 CONFIG_FILE，赋予默认值
    if [[ -z "$CONFIG_FILE" ]]; then
        CONFIG_FILE="/etc/sing-box/config.json"
        echo -e "${YELLOW}CONFIG_FILE 未定义，已默认使用 $CONFIG_FILE${PLAIN}"
    fi

    cat > /etc/systemd/system/sing-box.service <<EOF
[Unit]
Description=sing-box service
After=network.target nss-lookup.target

[Service]
ExecStart=/usr/local/bin/sing-box run -c $CONFIG_FILE
Restart=on-failure
RestartSec=10s
LimitNOFILE=infinity

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable sing-box

    # 如果存在 init_config 函数则调用，否则只创建配置目录
    if declare -F init_config &>/dev/null; then
        init_config
    else
        mkdir -p "$(dirname "$CONFIG_FILE")"
        echo -e "${YELLOW}init_config 函数未定义，已创建配置目录${PLAIN}"
    fi

    # ---------- 自复制脚本（避免覆盖自身） ----------
    if [[ "$0" != "/usr/local/bin/ssb" ]]; then
        cp "$0" /usr/local/bin/ssb && chmod +x /usr/local/bin/ssb
        echo -e "${GREEN}已安装 ssb 到 /usr/local/bin/ssb${PLAIN}"
    fi

    # ---------- 启动服务 ----------
    systemctl start sing-box
    echo -e "${GREEN}安装完成！请输入 ssb 管理。${PLAIN}"
    pause
}

add_node() {
    clear
    echo -e "${YELLOW}--- 添加节点配置 ---${PLAIN}"
    echo -e "1. VLESS + Reality"
    echo -e "2. TUIC v5"
    echo -e "3. Hysteria2"
    echo -e "4. Shadowsocks"
    echo -e "5. VLESS + WS + CF"
    echo -e "6. Socks5"
    echo -e "7. HTTPS Proxy"
    echo -e "8. Trojan"
    echo -e "0. 返回"
    read -p "请选择 [0-8]: " choice

    [[ "$choice" == "0" || -z "$choice" ]] && return

    # --- 基础变量初始化 ---
    local IP=$(get_ip)
    local UUID=$(uuidgen 2>/dev/null || cat /proc/sys/kernel/random/uuid)
    local LINK=""
    local TAG=""

    # 内部工具：生成随机密码
    gen_pass() {
        echo "$(openssl rand -base64 12 | tr -dc 'a-zA-Z0-9' | head -c 12)"
    }

    case $choice in
        1) # VLESS + Reality
            read -p "端口 (默认 443): " PORT; PORT=${PORT:-443}
            read -p "目标 SNI (默认 music.apple.com): " SNI; SNI=${SNI:-"music.apple.com"}
            TAG="reality-${PORT}"
            KEYS=$($SB_BIN generate reality-keypair)
            PRIVATE=$(echo "$KEYS" | awk -F': ' '/Private/ {print $2}' | tr -d '[:space:]')
            PUBLIC=$(echo "$KEYS" | awk -F': ' '/Public/ {print $2}' | tr -d '[:space:]')
            SID=$(openssl rand -hex 8)

            jq --arg port "$PORT" \
               --arg uuid "$UUID" \
               --arg sni "$SNI" \
               --arg priv "$PRIVATE" \
               --arg sid "$SID" \
               --arg tag "$TAG" \
               '.inbounds += [{
                    "type": "vless",
                    "tag": $tag,
                    "listen": "::",
                    "listen_port": ($port|tonumber),
                    "users": [{
                        "uuid": $uuid,
                        "flow": "xtls-rprx-vision"
                    }],
                    "tls": {
                        "enabled": true,
                        "server_name": $sni,
                        "reality": {
                            "enabled": true,
                            "handshake": {
                                "server": $sni,
                                "server_port": 443
                            },
                            "private_key": $priv,
                            "short_id": [$sid]
                        }
                    }
                }]' "$CONFIG_FILE" > tmp.json
            LINK="vless://$UUID@$IP:$PORT?security=reality&sni=$SNI&fp=chrome&pbk=$PUBLIC&sid=$SID&type=tcp&flow=xtls-rprx-vision#$TAG"
            ;;

        2|3|7|8) # 需要证书的协议 (TUIC, Hy2, HTTPS, Trojan)
            local p_type p_tag def_p
            [[ "$choice" == "2" ]] && p_type="tuic" && def_p="8443"
            [[ "$choice" == "3" ]] && p_type="hysteria2" && def_p="443"
            [[ "$choice" == "7" ]] && p_type="http" && def_p="443"
            [[ "$choice" == "8" ]] && p_type="trojan" && def_p="443"

            read -p "端口 (默认 $def_p): " PORT; PORT=${PORT:-$def_p}
            read -p "密码 (回车随机生成): " PASS; PASS=${PASS:-$(gen_pass)}
            TAG="${p_type}-${PORT}"

            echo -e "1. 自签名证书 | 2. 自动检测 ACME 证书 ($CERT_DIR)"
            read -p "证书类型: " c_choice
            if [[ "$c_choice" == "2" ]]; then
                read -p "对应域名: " domain
                find_certs "$domain"
                [[ -z "$CERT_PATH" ]] && {
                    echo -e "${RED}✘ 错误: 未在 $CERT_DIR/$domain 找到证书${PLAIN}"
                    pause
                    return
                }
                SNI_NAME="$domain"; ALLOW_INS="0"
            else
                CERT_PATH="/etc/sing-box/${p_type}.crt"
                KEY_PATH="/etc/sing-box/${p_type}.key"
                [[ ! -f "$CERT_PATH" ]] && openssl req -x509 -nodes -newkey ec:<(openssl ecparam -name prime256v1) \
                    -keyout "$KEY_PATH" -out "$CERT_PATH" -subj "/CN=apple.com" -days 3650 2>/dev/null
                SNI_NAME="apple.com"; ALLOW_INS="1"
            fi

            # 协议特定 JSON 构造
            if [[ "$p_type" == "tuic" ]]; then
                jq --arg port "$PORT" \
                   --arg uuid "$UUID" \
                   --arg pass "$PASS" \
                   --arg cert "$CERT_PATH" \
                   --arg key "$KEY_PATH" \
                   --arg tag "$TAG" \
                   '.inbounds += [{
                        "type": "tuic",
                        "tag": $tag,
                        "listen": "::",
                        "listen_port": ($port|tonumber),
                        "users": [{"uuid": $uuid, "password": $pass}],
                        "tls": {
                            "enabled": true,
                            "certificate_path": $cert,
                            "key_path": $key,
                            "alpn": ["h3"]
                        }
                    }]' "$CONFIG_FILE" > tmp.json
                LINK="tuic://$UUID:$PASS@$IP:$PORT?sni=$SNI_NAME&alpn=h3&allow_insecure=$ALLOW_INS&congestion_control=bbr#$TAG"
            elif [[ "$p_type" == "hysteria2" ]]; then
                jq --arg port "$PORT" \
                   --arg pass "$PASS" \
                   --arg cert "$CERT_PATH" \
                   --arg key "$KEY_PATH" \
                   --arg tag "$TAG" \
                   '.inbounds += [{
                        "type": "hysteria2",
                        "tag": $tag,
                        "listen": "::",
                        "listen_port": ($port|tonumber),
                        "users": [{"password": $pass}],
                        "tls": {
                            "enabled": true,
                            "certificate_path": $cert,
                            "key_path": $key
                        }
                    }]' "$CONFIG_FILE" > tmp.json
                LINK="hysteria2://$PASS@$IP:$PORT?insecure=$ALLOW_INS&sni=$SNI_NAME#$TAG"
            else # HTTPS / Trojan
                jq --arg port "$PORT" \
                   --arg pass "$PASS" \
                   --arg cert "$CERT_PATH" \
                   --arg key "$KEY_PATH" \
                   --arg tag "$TAG" \
                   --arg type "$p_type" \
                   '.inbounds += [{
                        "type": $type,
                        "tag": $tag,
                        "listen": "::",
                        "listen_port": ($port|tonumber),
                        "users": [{"password": $pass, "username": $pass}],
                        "tls": {
                            "enabled": true,
                            "certificate_path": $cert,
                            "key_path": $key
                        }
                    }]' "$CONFIG_FILE" > tmp.json
                LINK="${p_type}://$PASS@$SNI_NAME:$PORT?security=tls&sni=$SNI_NAME&allowInsecure=$ALLOW_INS#$TAG"
            fi
            ;;

        4) # Shadowsocks
            read -p "端口 (默认 8388): " PORT; PORT=${PORT:-8388}
            PASS=$(openssl rand -base64 16)
            METHOD="2022-blake3-aes-128-gcm"
            TAG="ss-${PORT}"
            jq --arg port "$PORT" \
               --arg pass "$PASS" \
               --arg method "$METHOD" \
               --arg tag "$TAG" \
               '.inbounds += [{
                    "type": "shadowsocks",
                    "tag": $tag,
                    "listen": "::",
                    "listen_port": ($port|tonumber),
                    "method": $method,
                    "password": $pass
                }]' "$CONFIG_FILE" > tmp.json
            LINK="ss://$(echo -n "$METHOD:$PASS" | base64 -w 0)@$IP:$PORT#$TAG"
            ;;

        5) # VLESS + WS + CF
            read -p "域名: " domain
            find_certs "$domain"
            [[ -z "$CERT_PATH" ]] && {
                echo -e "${RED}✘ 错误: 证书不存在${PLAIN}"
                pause
                return
            }
            read -p "端口 (默认 443): " PORT; PORT=${PORT:-443}
            read -p "路径 (默认 /video): " WSPATH; WSPATH=${WSPATH:-"/video"}
            TAG="vless-ws-${PORT}"
            jq --arg port "$PORT" \
               --arg uuid "$UUID" \
               --arg path "$WSPATH" \
               --arg domain "$domain" \
               --arg tag "$TAG" \
               --arg cert "$CERT_PATH" \
               --arg key "$KEY_PATH" \
               '.inbounds += [{
                    "type": "vless",
                    "tag": $tag,
                    "listen": "::",
                    "listen_port": ($port|tonumber),
                    "users": [{"uuid": $uuid}],
                    "transport": {"type": "ws", "path": $path},
                    "tls": {
                        "enabled": true,
                        "server_name": $domain,
                        "certificate_path": $cert,
                        "key_path": $key
                    }
                }]' "$CONFIG_FILE" > tmp.json
            LINK="vless://$UUID@$domain:$PORT?encryption=none&security=tls&type=ws&path=${WSPATH//\//%2F}#$TAG"
            ;;

        6) # Socks5
            read -p "端口: " PORT
            read -p "用户: " USER
            read -p "密码: " PASS
            TAG="socks-${PORT}"
            jq --arg port "$PORT" \
               --arg user "$USER" \
               --arg pass "$PASS" \
               --arg tag "$TAG" \
               '.inbounds += [{
                    "type": "socks",
                    "tag": $tag,
                    "listen": "::",
                    "listen_port": ($port|tonumber),
                    "users": [{"username": $user, "password": $pass}]
                }]' "$CONFIG_FILE" > tmp.json
            LINK="socks5://$USER:$PASS@$IP:$PORT#$TAG"
            ;;
    esac

    # --- 统一执行区 ---
    if [[ -f "tmp.json" ]]; then
        if save_and_restart; then
            [[ -n "$LINK" ]] && echo "$LINK" > "$LINK_DIR/${TAG}.link"
            echo -e "${GREEN}✔ 节点添加成功！${PLAIN}"
            echo -e "分享链接: ${BLUE}$LINK${PLAIN}"
        fi
        rm -f tmp.json
    fi
    pause
}

manage_configs() {
    clear
    echo -e "${YELLOW}--- 节点配置查看 ---${PLAIN}"
    local count=$(jq '.inbounds | length' "$CONFIG_FILE")
    if [[ "$count" -eq 0 ]]; then echo "暂无入站节点"; pause; return; fi

    # 1. 列表显示所有节点
    jq -r '.inbounds[] | "Tag: \(.tag) | Type: \(.type) | Port: \(.listen_port)"' "$CONFIG_FILE" | cat -n
    read -p "请选择要查看的序号 (q返回): " idx
    [[ "$idx" == "q" ]] && return

    # 2. 获取节点基本信息
    local TAG=$(jq -r ".inbounds[$(($idx-1))].tag" "$CONFIG_FILE")
    local CONF=$(jq -c ".inbounds[$(($idx-1))]" "$CONFIG_FILE")
    local TYPE=$(echo "$CONF" | jq -r .type)
    local PORT=$(echo "$CONF" | jq -r .listen_port)
    local IP=$(get_ip)

    # 3. 打印详情
    echo -e "\n${GREEN}================ 原始 JSON 配置 ================${PLAIN}"
    echo "$CONF" | jq .
    echo -e "${GREEN}===============================================${PLAIN}"

    echo -e "\n${YELLOW}>>>> 节点分享链接 <<<<${PLAIN}"
    
    # 优先使用持久化文件，不存在则动态生成
    if [[ -f "$LINK_DIR/${TAG}.link" ]]; then
        echo -e "${BLUE}$(cat "$LINK_DIR/${TAG}.link")${PLAIN}"
    else
        echo -e "${RED}未找到持久化链接文件，尝试根据当前配置生成...${PLAIN}"
        
        # 尝试从 TLS 配置中提取域名，如果提取不到则使用 IP
        local SNI=$(echo "$CONF" | jq -r '.tls.server_name // ""')
        local HOST=${SNI:-$IP}

        case $TYPE in
            vless)
                local UUID=$(echo "$CONF" | jq -r '.users[0].uuid')
                local SID=$(echo "$CONF" | jq -r '.tls.reality.short_id[0] // ""')
                if [[ -n "$SID" ]]; then
                    echo -e "${RED}Reality 节点的公钥不存储在配置文件中，无法生成完整链接。${PLAIN}"
                else
                    local WSPATH=$(echo "$CONF" | jq -r '.transport.path // ""')
                    echo -e "${BLUE}vless://$UUID@$HOST:$PORT?encryption=none&security=tls&type=ws&host=$SNI&path=$WSPATH#$TAG${PLAIN}"
                fi
                ;;
            tuic)
                local UUID=$(echo "$CONF" | jq -r '.users[0].uuid')
                local PASS=$(echo "$CONF" | jq -r '.users[0].password')
                echo -e "${BLUE}tuic://$UUID:$PASS@$HOST:$PORT?congestion_control=bbr&sni=$SNI&alpn=h3#$TAG${PLAIN}"
                ;;
            hysteria2)
                local PASS=$(echo "$CONF" | jq -r '.users[0].password')
                echo -e "${BLUE}hysteria2://$PASS@$HOST:$PORT?sni=$SNI#$TAG${PLAIN}"
                ;;
            shadowsocks)
                local METHOD=$(echo "$CONF" | jq -r .method); local PASS=$(echo "$CONF" | jq -r .password)
                local SS_BASE64=$(echo -n "$METHOD:$PASS" | base64 -w 0)
                echo -e "${BLUE}ss://$SS_BASE64@$IP:$PORT#$TAG${PLAIN}"
                ;;
            http)
                local USER=$(echo "$CONF" | jq -r '.users[0].username // ""')
                local PASS=$(echo "$CONF" | jq -r '.users[0].password // ""')
                if [[ -n "$USER" ]]; then
                    echo -e "${BLUE}https://$USER:$PASS@$HOST:$PORT#$TAG${PLAIN}"
                else
                    echo -e "${BLUE}https://$HOST:$PORT#$TAG${PLAIN}"
                fi
                ;;
            trojan)
                local PASS=$(echo "$CONF" | jq -r '.users[0].password // ""')
                local INSECURE=$(echo "$CONF" | jq -r '.tls.insecure // false')
                local INS_VAL="0"; [[ "$INSECURE" == "true" ]] && INS_VAL="1"
                echo -e "${BLUE}trojan://$PASS@$HOST:$PORT?security=tls&sni=$SNI&allowInsecure=$INS_VAL#$TAG${PLAIN}"
                ;;
            *)
                echo -e "${RED}暂不支持该协议 ($TYPE) 的链接还原${PLAIN}"
                ;;
        esac
    fi
    echo ""
    pause
}

edit_node() {
    clear
    echo -e "${YELLOW}--- 修改/删除节点配置 ---${PLAIN}"
    local count=$(jq '.inbounds | length' "$CONFIG_FILE")
    if [[ "$count" -eq 0 ]]; then echo "暂无入站节点"; pause; return; fi

    # 1. 列出节点
    jq -r '.inbounds[] | "Tag: \(.tag) | Type: \(.type) | Port: \(.listen_port)"' "$CONFIG_FILE" | cat -n
    read -p "请选择序号 (q返回): " idx
    [[ "$idx" == "q" ]] && return
    
    local i=$(($idx-1))
    local TAG=$(jq -r ".inbounds[$i].tag" "$CONFIG_FILE")
    local TYPE=$(jq -r ".inbounds[$i].type" "$CONFIG_FILE")

    echo -e "\n${CYAN}当前节点: $TAG ($TYPE)${PLAIN}"
    echo "1. 修改端口"
    echo "2. 修改 UUID / 密码"
    echo "3. 修改 SNI (域名)"
    echo "4. 删除此节点"
    echo "0. 返回"
    read -p "请选择操作: " op

    case $op in
        1)
            read -p "请输入新端口: " NEW_PORT
            [[ -z "$NEW_PORT" ]] && return
            jq ".inbounds[$i].listen_port = ($NEW_PORT|tonumber)" "$CONFIG_FILE" > tmp.json
            ;;
        2)
            # --- 身份凭据修改逻辑 ---
            local AUTH_FIELD=".users[0].uuid"
            # TUIC, Hy2, Trojan, HTTP 使用 password；VLESS 使用 uuid
            [[ "$TYPE" == "trojan" || "$TYPE" == "hysteria2" || "$TYPE" == "http" || "$TYPE" == "tuic" ]] && AUTH_FIELD=".users[0].password"
            [[ "$TYPE" == "shadowsocks" ]] && AUTH_FIELD=".password" 
            
            read -p "请输入新的身份凭证 (UUID/密码): " NEW_AUTH
            [[ -z "$NEW_AUTH" ]] && return
            
            # 如果是 TUIC，通常 UUID 和 Password 都会用到，这里我们默认修改 Password 字段
            # 如果你想同时改 TUIC 的 UUID，可以额外增加逻辑，但一般改 Password 即可生效
            jq ".inbounds[$i]$AUTH_FIELD = \"$NEW_AUTH\"" "$CONFIG_FILE" > tmp.json
            ;;
        3)
            read -p "请输入新的 SNI (域名): " NEW_SNI
            [[ -z "$NEW_SNI" ]] && return
            # 修改通用 TLS SNI
            jq ".inbounds[$i].tls.server_name = \"$NEW_SNI\" | 
                if .inbounds[$i].tls.reality then .inbounds[$i].tls.reality.handshake.server = \"$NEW_SNI\" else . end" "$CONFIG_FILE" > tmp.json
            ;;
        4)
            read -p "确定删除 $TAG 吗？(y/n): " confirm
            if [[ "$confirm" == "y" ]]; then
                jq "del(.inbounds[$i])" "$CONFIG_FILE" > tmp.json
                if save_and_restart; then
                    rm -f "$LINK_DIR/${TAG}.link"
                    echo -e "${GREEN}✔ 节点及持久化文件已删除${PLAIN}"
                fi
            fi
            pause && return
            ;;
        *) return ;;
    esac

    # 4. 保存并更新链接
    if [[ -f "tmp.json" ]]; then
        if save_and_restart; then
            echo -e "${GREEN}✔ 配置已更新！正在重新生成链接...${PLAIN}"
            
            local CONF=$(jq -c ".inbounds[$i]" "$CONFIG_FILE")
            local PORT=$(echo "$CONF" | jq -r .listen_port)
            local IP=$(get_ip)
            local SNI=$(echo "$CONF" | jq -r '.tls.server_name // ""')
            local HOST=${SNI:-$IP}
            local NEW_LINK=""

            case $TYPE in
                vless)
                    local UUID=$(echo "$CONF" | jq -r '.users[0].uuid')
                    local SID=$(echo "$CONF" | jq -r '.tls.reality.short_id[0] // ""')
                    local WSPATH=$(echo "$CONF" | jq -r '.transport.path // ""')
                    NEW_LINK="vless://$UUID@$HOST:$PORT?encryption=none&security=tls&type=ws&host=$SNI&path=$WSPATH#$TAG"
                    ;;
                tuic)
                    # --- 新增 TUIC 链接还原 ---
                    local UUID=$(echo "$CONF" | jq -r '.users[0].uuid')
                    local PASS=$(echo "$CONF" | jq -r '.users[0].password')
                    NEW_LINK="tuic://$UUID:$PASS@$HOST:$PORT?congestion_control=bbr&sni=$SNI&alpn=h3#$TAG"
                    ;;
                hysteria2)
                    # --- 新增 Hysteria2 链接还原 ---
                    local PASS=$(echo "$CONF" | jq -r '.users[0].password')
                    NEW_LINK="hysteria2://$PASS@$HOST:$PORT?sni=$SNI#$TAG"
                    ;;
                shadowsocks)
                    local METHOD=$(echo "$CONF" | jq -r .method); local PASS=$(echo "$CONF" | jq -r .password)
                    local SS_BASE64=$(echo -n "$METHOD:$PASS" | base64 -w 0)
                    NEW_LINK="ss://$SS_BASE64@$IP:$PORT#$TAG"
                    ;;
                trojan)
                    local PASS=$(echo "$CONF" | jq -r '.users[0].password'); local INS=$(echo "$CONF" | jq -r '.tls.insecure // false')
                    local IVAL="0"; [[ "$INS" == "true" ]] && IVAL="1"
                    NEW_LINK="trojan://$PASS@$HOST:$PORT?security=tls&sni=$SNI&allowInsecure=$IVAL#$TAG"
                    ;;
                http)
                    local USER=$(echo "$CONF" | jq -r '.users[0].username // ""'); local PASS=$(echo "$CONF" | jq -r '.users[0].password // ""')
                    NEW_LINK="https://$USER:$PASS@$HOST:$PORT#$TAG"
                    ;;
            esac

            # 更新持久化文件
            if [[ -n "$NEW_LINK" ]]; then
                echo "$NEW_LINK" > "$LINK_DIR/${TAG}.link"
                echo -e "${BLUE}新链接: $NEW_LINK${PLAIN}"
            fi
        fi
    fi
    pause
}

# 简单的解析函数：支持 ss:// 和 socks5://
parse_proxy_link() {
    local link=$1
    local content user_info server_info
    
    # 彻底清空全局变量，防止逻辑污染
    R_ADDR=""; R_PORT=""; R_METHOD=""; R_PASS=""; R_USER=""; hop_type=""

    if [[ "$link" =~ ^ss:// ]]; then
        hop_type=1
        content=$(echo "${link#ss://}" | cut -d'#' -f1)
        if [[ "$content" == *"@"* ]]; then
            # SIP002 格式
            local user_info_b64=$(echo "$content" | cut -d'@' -f1)
            server_info=$(echo "$content" | cut -d'@' -f2)
            user_info=$(echo "$user_info_b64" | tr '_-' '/+' | awk '{printf "%s%s", $0, substr("===", 1, (4-length($0)%4)%4)}' | base64 -d 2>/dev/null)
            R_METHOD=$(echo "$user_info" | cut -d':' -f1)
            R_PASS=$(echo "$user_info" | cut -d':' -f2)
            R_ADDR=$(echo "$server_info" | cut -d':' -f1)
            R_PORT=$(echo "$server_info" | cut -d':' -f2 | cut -d'/' -f1)
        else
            # 全包 Base64 格式
            local decoded=$(echo "$content" | tr '_-' '/+' | awk '{printf "%s%s", $0, substr("===", 1, (4-length($0)%4)%4)}' | base64 -d 2>/dev/null)
            if [[ "$decoded" =~ ^(.+):(.+)@(.+):([0-9]+) ]]; then
                R_METHOD="${BASH_REMATCH[1]}"; R_PASS="${BASH_REMATCH[2]}"
                R_ADDR="${BASH_REMATCH[3]}"; R_PORT="${BASH_REMATCH[4]}"
            fi
        fi
    elif [[ "$link" =~ ^socks5:// ]]; then
        hop_type=2
        content=${link#socks5://}; content=$(echo "$content" | cut -d'#' -f1)
        if [[ "$content" == *"@"* ]]; then
            user_info=$(echo "$content" | cut -d'@' -f1); server_info=$(echo "$content" | cut -d'@' -f2)
            R_USER=$(echo "$user_info" | cut -d':' -f1); R_PASS=$(echo "$user_info" | cut -d':' -f2)
            R_ADDR=$(echo "$server_info" | cut -d':' -f1); R_PORT=$(echo "$server_info" | cut -d':' -f2)
        else
            R_ADDR=$(echo "$content" | cut -d':' -f1); R_PORT=$(echo "$content" | cut -d':' -f2)
        fi
    elif [[ "$link" =~ ^https:// ]]; then
        hop_type=3
        content=${link#https://}; content=$(echo "$content" | cut -d'#' -f1)
        if [[ "$content" == *"@"* ]]; then
            user_info=$(echo "$content" | cut -d'@' -f1); server_info=$(echo "$content" | cut -d'@' -f2)
            R_USER=$(echo "$user_info" | cut -d':' -f1); R_PASS=$(echo "$user_info" | cut -d':' -f2)
            R_ADDR=$(echo "$server_info" | cut -d':' -f1); R_PORT=$(echo "$server_info" | cut -d':' -f2)
        else
            R_ADDR=$(echo "$content" | cut -d':' -f1); R_PORT=$(echo "$content" | cut -d':' -f2)
        fi
    fi
}

# --- 链式代理：链路管理与强制重定向 ---
chain_proxy() {
    local cp_choice idx LOCAL_TAG RAW_LINK R_ADDR R_PORT R_METHOD R_PASS R_USER \
          hop_type SKIP_TLS OUT_TAG OUT_JSON CURRENT_OUTBOUND NEW_RULE_JSON

    while true; do
        clear
        echo -e "${YELLOW}================================================${PLAIN}"
        echo -e "${YELLOW}           链式代理与链路管理           ${PLAIN}"
        echo -e "${YELLOW}================================================${PLAIN}"
        echo " 1. 添加跳转节点 链式)"
        echo " 2. 查看当前活跃链路"
        echo " 3. 重置入站规则 (恢复直连)"
        echo " 0. 返回主菜单"
        echo "------------------------------------------------"
        read -p "请选择: " cp_choice


        # --- 0. 退出逻辑 ---
        [[ "$cp_choice" == "0" ]] && return 0


        case $cp_choice in
            1)
                # --- A. 选择入站节点 ---
                echo -e "\n${CYAN}[步骤1] 选择流量进入的入站 (Inbound):${PLAIN}"
                jq -r '.inbounds | keys[] as $i | "\($i+1)) Tag: \(.[$i].tag) [\(.[$i].type)]"' "$CONFIG_FILE"
                read -p "选择序号: " idx
                [[ -z "$idx" ]] && continue
                LOCAL_TAG=$(jq -r ".inbounds[$((idx-1))].tag" "$CONFIG_FILE")
                
                # 精准获取当前出口 (兼容数组和字符串格式)
                CURRENT_OUTBOUND=$(jq -r --arg itag "$LOCAL_TAG" '
                    .route.rules[] | 
                    select(if .inbound | type == "array" then .inbound | contains([$itag]) else .inbound == $itag end) | 
                    .outbound' "$CONFIG_FILE" | head -n 1)


                # --- B. 获取新节点信息 ---
                echo -e "\n${CYAN}[步骤2] 配置出口节点 (Outbound):${PLAIN}"
                read -p "粘贴链接 (回车手动输入): " RAW_LINK
                
                # 清理旧变量
                R_ADDR=""; R_PORT=""; R_METHOD=""; R_PASS=""; R_USER=""; hop_type=""

                if [[ -n "$RAW_LINK" ]]; then
                    parse_proxy_link "$RAW_LINK"
                fi

                if [[ -z "$R_ADDR" ]]; then
                    echo -e "\n${YELLOW}>> 手动输入模式:${PLAIN}"
                    echo "1) Shadowsocks  2) Socks5  3) HTTPS"
                    read -p "协议选择: " hop_type
                    case $hop_type in
                        1) read -p "地址: " R_ADDR; read -p "端口[8388]: " R_PORT; R_PORT=${R_PORT:-8388}
                           read -p "加密[aes-128-gcm]: " R_METHOD; R_METHOD=${R_METHOD:-aes-128-gcm}
                           read -p "密码: " R_PASS ;;
                        2) read -p "地址: " R_ADDR; read -p "端口[1080]: " R_PORT; R_PORT=${R_PORT:-1080}
                           read -p "用户: " R_USER; read -p "密码: " R_PASS ;;
                        3) read -p "地址: " R_ADDR; read -p "端口[443]: " R_PORT; R_PORT=${R_PORT:-443}
                           read -p "用户: " R_USER; read -p "密码: " R_PASS ;;
                    esac
                fi

                [[ -z "$R_ADDR" ]] && echo -e "${RED}输入无效${PLAIN}" && sleep 1 && continue


                # --- C. HTTPS 证书预处理 ---
                SKIP_TLS="n"
                if [[ "$hop_type" == "3" || "$RAW_LINK" =~ ^https:// ]]; then
                    read -p "是否跳过证书验证 (Insecure)? [y/N]: " SKIP_TLS
                    SKIP_TLS=${SKIP_TLS:-n}
                fi


                # --- D. 构造 JSON 对象 ---
                OUT_TAG="chain-$(date +%s)"

                # 构造节点 JSON
                OUT_JSON=$(jq -n \
                    --arg t "$OUT_TAG" --arg s "$R_ADDR" --arg p "$R_PORT" \
                    --arg m "$R_METHOD" --arg pass "$R_PASS" --arg u "$R_USER" \
                    --arg d "$CURRENT_OUTBOUND" --arg ht "$hop_type" --arg skip "$SKIP_TLS" \
                    '
                    (if $ht == "1" then
                        {type: "shadowsocks", tag: $t, server: $s, server_port: ($p|tonumber), method: $m, password: $pass}
                    elif $ht == "2" then
                        {type: "socks", tag: $t, server: $s, server_port: ($p|tonumber), version: "5"} + (if $u != "" then {username: $u, password: $pass} else {} end)
                    elif $ht == "3" then
                        {type: "http", tag: $t, server: $s, server_port: ($p|tonumber), tls: {enabled: true, insecure: ($skip == "y" or $skip == "Y")}} + (if $u != "" then {username: $u, password: $pass} else {} end)
                    else empty end) 
                    | if ($d != "" and $d != "null" and $d != "direct") then . + {detour: $d} else . end
                    ' -c)

                # 构造路由规则 JSON (强制为数组格式)
                NEW_RULE_JSON=$(jq -n --arg itag "$LOCAL_TAG" --arg otag "$OUT_TAG" '{"inbound": [$itag], "outbound": $otag}')


                # --- E. 物理写入与安全检查 ---
                echo -e "\n${CYAN}[步骤3] 正在应用配置...${PLAIN}"

                # 逻辑：先在 outbounds 添加节点，再重构 route.rules (新规则置顶 + 过滤掉该入站的旧规则)
                jq --argjson newNode "$OUT_JSON" --argjson newRule "$NEW_RULE_JSON" --arg itag "$LOCAL_TAG" '
                    .outbounds += [$newNode] |
                    .route.rules = (
                        [$newRule] + 
                        [ .route.rules[] | select(
                            if .inbound then 
                                (if .inbound | type == "array" then .inbound | contains([$itag]) | not else .inbound != $itag end)
                            else true end
                        ) ]
                    )
                ' "$CONFIG_FILE" > tmp.json

                if [[ -s tmp.json ]] && /usr/local/bin/sing-box check -c tmp.json > /dev/null 2>&1; then
                    mv tmp.json "$CONFIG_FILE"
                    systemctl restart sing-box
                    echo -e "${GREEN}✔ 配置成功！${PLAIN}"
                    echo -e "链路详情: ${BLUE}$LOCAL_TAG${PLAIN} -> ${GREEN}$OUT_TAG${PLAIN} -> ${YELLOW}${CURRENT_OUTBOUND:-"互联网"}${PLAIN}"
                else
                    echo -e "${RED}✖ 错误：配置校验失败，已回滚。${PLAIN}"
                    /usr/local/bin/sing-box check -c tmp.json
                    rm -f tmp.json
                fi
                pause
                ;;

            2)
                echo -e "\n${YELLOW}--- 当前活跃转发链路 ---${PLAIN}"
                jq -r '.route.rules[] | select(.inbound != null) | "入站: \(.inbound)  ==>  出口: \(.outbound)"' "$CONFIG_FILE"
                pause
                ;;

            3)
                echo -e "\n${YELLOW}选择要重置为直连的入站:${PLAIN}"
                # 提取所有有规则的入站标签
                local in_tags=$(jq -r '.route.rules[] | select(.inbound != null) | .inbound | if type == "array" then .[0] else . end' "$CONFIG_FILE")
                echo "$in_tags" | cat -n
                read -p "选择序号: " del_idx
                local DEL_IN_TAG=$(echo "$in_tags" | sed -n "${del_idx}p")

                if [[ -n "$DEL_IN_TAG" ]]; then
                    jq --arg itag "$DEL_IN_TAG" '
                        .route.rules |= map(if (if .inbound | type == "array" then .inbound | contains([$itag]) else .inbound == $itag end) then .outbound = "direct" else . end)
                    ' "$CONFIG_FILE" > tmp.json && mv tmp.json "$CONFIG_FILE"
                    systemctl restart sing-box
                    echo -e "${GREEN}✔ 入站 [$DEL_IN_TAG] 已恢复直连。${PLAIN}"
                fi
                pause
                ;;
        esac
    done
}

manage_routing() {
    local rt_choice IN_TAGS OUT_TAG OUT_JSON RULE_JSON
    
    while true; do
        clear
        echo -e "${YELLOW}--- 网站分流/路由管理 ---${PLAIN}"
        echo "1. 添加分流规则 (入站 + 目标 -> 指定出站)"
        echo "2. 查看当前分流规则"
        echo "3. 删除特定分流规则"
        echo "0. 返回主菜单"
        echo "------------------------------------------------"
        read -p "请选择: " rt_choice

        case $rt_choice in
            1)
                # --- 1. 选择入站 ---
                echo -e "\n${CYAN}1. 请选择来源入站:${PLAIN}"
                local in_count=$(jq '.inbounds | length' "$CONFIG_FILE")
                [[ "$in_count" -eq 0 ]] && echo -e "${RED}无入站配置${PLAIN}" && pause && continue
                jq -r '.inbounds | keys[] as $i | "\($i+1)) Tag: \(.[$i].tag) [\(.[$i].type)]"' "$CONFIG_FILE"
                read -p "选择序号 (逗号隔开, 回车代表全部): " in_idxs
                if [[ -z "$in_idxs" ]]; then IN_TAGS="null"; else
                    IN_TAGS=$(echo "$in_idxs" | tr ',' '\n' | while read -r i; do jq -r ".inbounds[$((i-1))].tag" "$CONFIG_FILE"; done | jq -R . | jq -s . -c)
                fi

                # --- 2. 匹配目标 ---
                echo -e "\n${CYAN}2. 请选择匹配的目标:${PLAIN}"
                echo "1) 全部流量 | 2) 域名匹配 | 3) GeoSite | 4) IP/CIDR"
                read -p "选择 [1-4]: " target_type
                local RULE_PART="{}"
                case $target_type in
                    2) read -p "域名: " val; RULE_PART=$(echo "$val" | tr ',' '\n' | jq -R . | jq -s '{"domain": .}' -c) ;;
                    3) read -p "GeoSite: " val; RULE_PART=$(echo "$val" | tr ',' '\n' | jq -R . | jq -s '{"geosite": .}' -c) ;;
                    4) read -p "IP/CIDR: " val; RULE_PART=$(echo "$val" | tr ',' '\n' | jq -R . | jq -s '{"ip_cidr": .}' -c) ;;
                esac

                # --- 3. 出站配置 (移除引发报错的非法字段) ---
                echo -e "\n${CYAN}3. 请配置目标出站:${PLAIN}"
                echo "1) 粘贴链接 | 2) 手动输入 | 3) 自动优选 (URL-Test) | 4) 节点组 (Selector)"
                read -p "选择 [1-4]: " out_mode
                
                OUT_TAG="route-out-$(date +%s)"
                OUT_JSON=""

                if [[ "$out_mode" == "1" ]]; then
                    R_ADDR=""; R_PORT=""; R_METHOD=""; R_PASS=""; 
                    read -p "输入链接: " RAW_LINK; parse_proxy_link "$RAW_LINK"
                    [[ -z "$R_ADDR" ]] && echo -e "${RED}解析失败${PLAIN}" && pause && continue
                    OUT_JSON=$(jq -n --arg t "$OUT_TAG" --arg s "$R_ADDR" --arg p "$R_PORT" --arg m "$R_METHOD" --arg pass "$R_PASS" \
                        '{"type":"shadowsocks","tag":$t,"server":$s,"server_port":($p|tonumber),"method":$m,"password":$pass}')
                elif [[ "$out_mode" == "2" ]]; then
                    echo -e "1) SS | 2) Socks5 | 3) HTTPS"; read -p "协议: " h_type
                    read -p "地址: " R_ADDR; read -p "端口: " R_PORT
                    case $h_type in
                        1) read -p "加密: " R_METHOD; read -p "密码: " R_PASS; OUT_JSON=$(jq -n --arg t "$OUT_TAG" --arg s "$R_ADDR" --arg p "$R_PORT" --arg m "$R_METHOD" --arg pass "$R_PASS" '{"type":"shadowsocks","tag":$t,"server":$s,"server_port":($p|tonumber),"method":$m,"password":$pass}') ;;
                        2) read -p "用户: " R_USER; read -p "密码: " R_PASS; OUT_JSON=$(jq -n --arg t "$OUT_TAG" --arg s "$R_ADDR" --arg p "$R_PORT" --arg u "$R_USER" --arg pass "$R_PASS" '{"type":"socks","tag":$t,"server":$s,"server_port":($p|tonumber),"version":"5"} + (if $u != "" then {"username":$u,"password":$pass} else {} end)') ;;
                        3) read -p "用户: " R_USER; read -p "密码: " R_PASS; OUT_JSON=$(jq -n --arg t "$OUT_TAG" --arg s "$R_ADDR" --arg p "$R_PORT" --arg u "$R_USER" --arg pass "$R_PASS" '{"type":"http","tag":$t,"server":$s,"server_port":($p|tonumber),"tls":{"enabled":true}} + (if $u != "" then {"username":$u,"password":$pass} else {} end)') ;;
                    esac
                elif [[ "$out_mode" == "3" || "$out_mode" == "4" ]]; then
                    echo -e "\n${YELLOW}选择代理成员 (多选用逗号):${PLAIN}"
                    # 过滤直连和系统节点
                    jq -r '.outbounds | keys[] as $i | select(.[$i].type != "direct" and .[$i].type != "dns" and .[$i].type != "block") | "\($i+1)) [\(.[$i].type)] \(.[$i].tag)"' "$CONFIG_FILE"
                    read -p "序号: " m_idxs
                    [[ -z "$m_idxs" ]] && continue
                    MEMBER_TAGS=$(echo "$m_idxs" | tr ',' '\n' | while read -r i; do jq -r ".outbounds[$((i-1))].tag" "$CONFIG_FILE"; done | jq -R . | jq -s . -c)
                    OUT_TAG="group-out-$(date +%s)"
                    if [[ "$out_mode" == "3" ]]; then
                        # URL-Test 测速自动切换
                        OUT_JSON=$(jq -n --arg t "$OUT_TAG" --argjson m "$MEMBER_TAGS" '{"type":"urltest","tag":$t,"outbounds":$m,"url":"https://www.gstatic.com/generate_204","interval":"3m0s"}')
                    else
                        # 真正的 Selector (删除了引发报错的 strategy 字段)
                        OUT_JSON=$(jq -n --arg t "$OUT_TAG" --argjson m "$MEMBER_TAGS" '{"type":"selector","tag":$t,"outbounds":$m}')
                    fi
                fi

                # --- 4. 写入配置并诊断 ---
                RULE_JSON=$(echo "$RULE_PART" | jq --arg ot "$OUT_TAG" --argjson it "$IN_TAGS" '. + {"outbound": $ot} + (if $it != null then {"inbound": $it} else {} end)' -c)
                
                jq --argjson out_obj "$OUT_JSON" --argjson rule_obj "$RULE_JSON" \
                   '.outbounds += [$out_obj] | .route.rules = [$rule_obj] + .route.rules' "$CONFIG_FILE" > tmp.json
                
                # 显式捕捉错误原因，替代静默失败
                if save_and_restart; then
                    echo -e "${GREEN}✔ 添加成功，配置已生效！${PLAIN}"
                else
                    echo -e "${RED}✖ 配置语法检查失败！核心错误信息如下：${PLAIN}"
                    $SB_BIN check -c tmp.json
                    rm -f tmp.json
                fi
                pause ;;

            2)
                echo -e "\n${CYAN}当前规则:${PLAIN}"
                jq -r '.route.rules | keys[] as $i | "\($i+1)) [\(.[$i].inbound // "全部")] -> [\(.[$i].outbound)]"' "$CONFIG_FILE"
                pause ;;

            3)
                echo -e "\n${YELLOW}删除序号 (all 代表全部):${PLAIN}"
                jq -r '.route.rules | keys[] as $i | "\($i+1)) \(.[$i].outbound)"' "$CONFIG_FILE"
                read -p "> " d_choice
                if [[ "$d_choice" == "all" ]]; then
                    jq '.route.rules = [] | .outbounds |= map(select(.tag | (startswith("route-out-") or startswith("group-out-")) | not))' "$CONFIG_FILE" > tmp.json
                else
                    local j_idxs=$(echo "$d_choice" | tr ',' '\n' | awk '{print $1-1}' | jq -R . | jq -s . -c)
                    jq --argjson idxs "$j_idxs" 'del(.route.rules[$idxs[]])' "$CONFIG_FILE" > tmp_s.json
                    jq '.outbounds |= map(select(((.tag | (startswith("route-out-") or startswith("group-out-"))) | not) or (.tag as $t | any(.route.rules[]; .outbound == $t))))' tmp_s.json > tmp.json
                    rm -f tmp_s.json
                fi
                
                if save_and_restart; then
                    echo -e "${GREEN}✔ 已更新${PLAIN}"
                else
                    echo -e "${RED}✖ 语法检查失败！核心错误信息如下：${PLAIN}"
                    $SB_BIN check -c tmp.json
                    rm -f tmp.json
                fi
                pause ;;
            0) return 0 ;;
        esac
    done
}

# --- 添加基础出站节点 ---
add_outbound() {
    local node_type R_ADDR R_PORT R_METHOD R_PASS R_USER RAW_LINK OUT_TAG OUT_JSON
    
    while true; do
        clear
        echo -e "${YELLOW}--- 添加基础出站节点 ---${PLAIN}"
        echo "1. 粘贴分享链接 (SS / Socks5)"
        echo "2. 手动输入配置 (SS / Socks5 / HTTPS)"
        echo "0. 返回主菜单"
        echo "------------------------------------------------"
        read -p "请选择 [0-2]: " node_type

        [[ "$node_type" == "0" ]] && break

        OUT_TAG="hop-$(date +%s)" # 自动生成节点标签
        R_ADDR=""; R_PORT=""; R_METHOD=""; R_PASS=""; R_USER=""

        if [[ "$node_type" == "1" ]]; then
            # --- 链接解析模式 ---
            read -p "请输入节点链接: " RAW_LINK
            # 调用解析函数 (需确保脚本内有 parse_proxy_link 函数)
            parse_proxy_link "$RAW_LINK" 
            
            if [[ -z "$R_ADDR" ]]; then
                echo -e "${RED}错误：链接解析失败，请检查格式！${PLAIN}"
                pause && continue
            fi
        elif [[ "$node_type" == "2" ]]; then
            # --- 手动输入模式 ---
            echo -e "\n请选择协议: 1) SS  2) Socks5  3) HTTPS"
            read -p "选择: " proto_choice
            read -p "地址 (Domain/IP): " R_ADDR
            read -p "端口 (Port): " R_PORT
            
            case $proto_choice in
                1)
                    read -p "加密方式 (如 aes-256-gcm): " R_METHOD
                    read -p "密码: " R_PASS
                    OUT_JSON=$(jq -n --arg t "$OUT_TAG" --arg s "$R_ADDR" --arg p "$R_PORT" --arg m "$R_METHOD" --arg pass "$R_PASS" \
                        '{"type":"shadowsocks","tag":$t,"server":$s,"server_port":($p|tonumber),"method":$m,"password":$pass}')
                    ;;
                2)
                    read -p "用户名 (可选): " R_USER
                    read -p "密码 (可选): " R_PASS
                    OUT_JSON=$(jq -n --arg t "$OUT_TAG" --arg s "$R_ADDR" --arg p "$R_PORT" --arg u "$R_USER" --arg pass "$R_PASS" \
                        '{"type":"socks","tag":$t,"server":$s,"server_port":($p|tonumber),"version":"5"} + (if $u != "" then {"username":$u,"password":$pass} else {} end)')
                    ;;
                3)
                    read -p "用户名 (可选): " R_USER
                    read -p "密码 (可选): " R_PASS
                    OUT_JSON=$(jq -n --arg t "$OUT_TAG" --arg s "$R_ADDR" --arg p "$R_PORT" --arg u "$R_USER" --arg pass "$R_PASS" \
                        '{"type":"http","tag":$t,"server":$s,"server_port":($p|tonumber),"tls":{"enabled":true}} + (if $u != "" then {"username":$u,"password":$pass} else {} end)')
                    ;;
                *) echo -e "${RED}非法输入${PLAIN}"; continue ;;
            esac
        fi

        # 如果是链接解析过来的，需要根据解析结果构造 JSON
        if [[ -z "$OUT_JSON" && -n "$R_ADDR" ]]; then
            if [[ -n "$R_METHOD" ]]; then # SS
                OUT_JSON=$(jq -n --arg t "$OUT_TAG" --arg s "$R_ADDR" --arg p "$R_PORT" --arg m "$R_METHOD" --arg pass "$R_PASS" \
                    '{"type":"shadowsocks","tag":$t,"server":$s,"server_port":($p|tonumber),"method":$m,"password":$pass}')
            else # Socks5
                OUT_JSON=$(jq -n --arg t "$OUT_TAG" --arg s "$R_ADDR" --arg p "$R_PORT" --arg u "$R_USER" --arg pass "$R_PASS" \
                    '{"type":"socks","tag":$t,"server":$s,"server_port":($p|tonumber),"version":"5"} + (if $u != "" then {"username":$u,"password":$pass} else {} end)')
            fi
        fi

        # --- 写入配置文件 ---
        if [[ -n "$OUT_JSON" ]]; then
            jq --argjson obj "$OUT_JSON" '.outbounds += [$obj]' "$CONFIG_FILE" > tmp.json
            
            if save_and_restart; then
                echo -e "${GREEN}✔ 节点 [$OUT_TAG] 添加成功！${PLAIN}"
            else
                echo -e "${RED}✖ 语法检查失败，节点未添加。${PLAIN}"
                $SB_BIN check -c tmp.json
                rm -f tmp.json
            fi
        fi
        pause
    done
}

update_all() {
    echo -e "${CYAN}请选择更新项:${PLAIN}"
    echo "1. 更新管理脚本 | 2. 更新 sing-box 内核 | 0. 返回"
    read -p "选择: " uc
    [[ "$uc" == "0" ]] && return
    if [ "$uc" == "1" ]; then
        curl -Ls "$UPDATE_URL" -o /usr/local/bin/ssb
        chmod +x /usr/local/bin/ssb
        echo -e "${GREEN}脚本更新完成${PLAIN}"
        exit 0
    else
        install_base
    fi
}

enable_bbr() {
    echo -e "${YELLOW}正在检查 BBR 状态...${PLAIN}"
    local kernel_version=$(uname -r | cut -d- -f1)
    if [[ $(echo -e "4.9\n$kernel_version" | sort -V | head -n1) == "4.9" ]]; then
        if lsmod | grep -q bbr; then
            echo -e "${GREEN}BBR 已经处于运行状态。${PLAIN}"
        else
            echo -e "${CYAN}正在开启 BBR...${PLAIN}"
            echo "net.core.default_qdisc=fq" >> /etc/sysctl.conf
            echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf
            sysctl -p >/dev/null 2>&1
            if lsmod | grep -q bbr; then
                echo -e "${GREEN}BBR 成功开启！${PLAIN}"
            else
                echo -e "${RED}BBR 开启失败。${PLAIN}"
            fi
        fi
    else
        echo -e "${RED}内核版本过低 ($kernel_version)，不支持 BBR。${PLAIN}"
    fi
    pause
}

# --- 主菜单 ---
while true; do
    clear
    echo -e "--- ${YELLOW}sing-box 综合管理脚本 (ssb)${PLAIN} ---"
    show_status
    echo "--------------------------------"
    echo "1. 安装 / 重装 sing-box"
    echo "2. 节点快速配置"
    echo "3. 配置/链接查看"
    echo "4. 链路管理（中转/落地/链式)"
    echo "5. 分流设置/管理"
    echo "6. 更新脚本或内核"
    echo "7. 备份 / 还原"
    echo "8. 开启 BBR 网络加速"
    echo "9. 申请 SSL 域名证书 (ACME)"
    echo "10. 添加出站/用于自动/负载"
    echo "11 更改配置/删除"
    echo "77. 彻底卸载"
    echo -e " \033[1;32m  [88]  重启 sing-box 服务\033[0m"
    echo "0. 退出"
    read -p "选择 [0-88]: " num
    
    case "$num" in
        1) install_base ;;
        2) add_node ;;
        3) manage_configs ;;
        4) chain_proxy;;
        5) manage_routing ;;
        6) update_all ;;
        7) backup_restore ;;
        8) enable_bbr ;;
        9) apply_cert ;;
        10) add_outbound ;;
        11) edit_node ;;
        77)
            read -p "确定卸载吗？此操作不可逆！(y/n): " confirm
            if [[ "$confirm" == "y" ]]; then
                systemctl stop sing-box
                systemctl disable sing-box
                rm -f /etc/systemd/system/sing-box.service
                systemctl daemon-reload
                rm -f /usr/local/bin/ssb /usr/local/bin/sing-box
                rm -rf /etc/sing-box
                echo -e "${GREEN}sing-box 及相关配置已彻底卸载。${PLAIN}"
                exit 0
            fi
            ;;
        88)
            echo -e "${YELLOW}正在重启服务...${PLAIN}"
            systemctl restart sing-box
            sleep 1
            ;;
        0) 
            echo -e "${GREEN}脚本已退出。${PLAIN}"
            exit 0 
            ;;
        *) 
            echo -e "${RED}输入错误，请重新选择${PLAIN}"
            sleep 1
            ;;
    esac
done
