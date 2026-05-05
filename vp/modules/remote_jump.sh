#!/bin/bash
# 远程 SSH 跳转模块

if [ -z "$VPS_COMMON_LOADED" ]; then
    source /usr/local/share/vp_modules/common.sh 2>/dev/null || {
        echo "无法加载公共函数库"
        exit 1
    }
fi

REMOTE_CONF="/etc/vp_manager_remotes.conf"
[ ! -f "$REMOTE_CONF" ] && touch "$REMOTE_CONF" && chmod 600 "$REMOTE_CONF"

setup_ssh_key() {
    local user=$1 ip=$2 port=$3
    [ ! -f ~/.ssh/id_rsa ] && ssh-keygen -t rsa -N "" -f ~/.ssh/id_rsa
    printf "${YELLOW}正在分发公钥 (仅需此次输入密码)...${PLAIN}\n"
    ssh-copy-id -p "$port" "$user@$ip"
}

delete_remote_host() {
    if [ ! -s "$REMOTE_CONF" ]; then
        printf "${RED}列表为空，无需删除。${PLAIN}\n"
        return
    fi
    printf "${YELLOW}选择要删除的主机编号:${PLAIN}\n"
    local i=1
    while IFS='|' read -r r_alias r_user r_ip r_port r_key; do
        printf "%d. %s (%s)\n" "$i" "$r_alias" "$r_ip"
        ((i++))
    done < "$REMOTE_CONF"
    read -p "请输入编号 (0取消): " del_num
    if [[ "$del_num" =~ ^[0-9]+$ ]] && [ "$del_num" -gt 0 ] && [ "$del_num" -lt "$i" ]; then
        sed -i "${del_num}d" "$REMOTE_CONF"
        printf "${GREEN}删除成功。${PLAIN}\n"
    fi
    sleep 1
}

add_remote_host() {
    clear
    printf "${BLUE}===== 添加远程主机 =====${PLAIN}\n"
    read -p "主机别名: " alias_name
    read -p "远程 IP: " r_ip
    read -p "SSH 端口 (默认 22): " r_port && r_port=${r_port:-22}
    read -p "用户名 (默认 root): " r_user && r_user=${r_user:-root}
    
    printf "\n1) 密码/已免密  2) 指定私钥路径\n"
    read -p "请选择: " auth_type
    if [[ "$auth_type" == "2" ]]; then
        read -p "请输入私钥路径: " key_path
        [ -f "$key_path" ] && echo "$alias_name|$r_user|$r_ip|$r_port|$key_path" >> "$REMOTE_CONF" || echo "$alias_name|$r_user|$r_ip|$r_port|none" >> "$REMOTE_CONF"
    else
        echo "$alias_name|$r_user|$r_ip|$r_port|none" >> "$REMOTE_CONF"
        read -p "配置免密登录? (y/n): " is_key
        [[ "$is_key" == "y" ]] && setup_ssh_key "$r_user" "$r_ip" "$r_port"
    fi
    printf "${GREEN}保存成功！${PLAIN}\n"
    sleep 1
}

remote_jump_menu() {
    while true; do
        clear
        printf "${GREEN}========== 远程 SSH 跳转中心 ==========${PLAIN}\n"
        if [ ! -s "$REMOTE_CONF" ]; then
            printf "${YELLOW}尚未添加任何远程主机。${PLAIN}\n"
        else
            declare -a aliases users ips ports keys
            local i=1
            while IFS='|' read -r r_alias r_user r_ip r_port r_key; do
                printf "%2d. %-15s [%s@%s:%s]\n" "$i" "$r_alias" "$r_user" "$r_ip" "$r_port"
                aliases[$i]="$r_alias"
                users[$i]="$r_user"
                ips[$i]="$r_ip"
                ports[$i]="$r_port"
                keys[$i]="$r_key"
                ((i++))
            done < "$REMOTE_CONF"
            local max_index=$((i-1))
        fi
        printf "--------------------------------------\n"
        printf "a. 添加主机  d. 删除主机  0. 返回主菜单\n"
        read -p "选择编号: " choice
        case "$choice" in
            0) break ;;
            a) add_remote_host ;;
            d) delete_remote_host ;;
            *)
                if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -gt 0 ] && [ "$choice" -le "$max_index" ]; then
                    local u="${users[$choice]}" ip="${ips[$choice]}" p="${ports[$choice]}" k="${keys[$choice]}"
                    [[ "$k" != "none" ]] && ssh -i "$k" -p "$p" "$u@$ip" || ssh -p "$p" "$u@$ip"
                    break
                fi ;;
        esac
    done
}

remote_jump_menu
