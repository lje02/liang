#!/bin/bash
# 日志查看与分析模块

if [ -z "$VPS_COMMON_LOADED" ]; then
    source /usr/local/share/vp_modules/common.sh 2>/dev/null || {
        echo "无法加载公共函数库"
        exit 1
    }
fi

detect_os
check_dependencies

# 日志路径自动检测
AUTH_LOG="/var/log/auth.log"
SYS_LOG="/var/log/syslog"
KERN_LOG="/var/log/kern.log"
FAIL2BAN_LOG="/var/log/fail2ban.log"
NGINX_LOG="/var/log/nginx/access.log"

# 适配 RHEL 系
[ -f /var/log/secure ] && AUTH_LOG="/var/log/secure"
[ -f /var/log/messages ] && SYS_LOG="/var/log/messages"

# 显示日志文件内容
view_log() {
    local file="$1"
    local title="$2"
    if [ ! -f "$file" ]; then
        printf "${RED}日志文件不存在: %s${NC}\n" "$file"
        read -p "按回车键继续..." dummy
        return
    fi
    clear
    printf "${BLUE}===== %s =====${NC}\n" "$title"
    printf "文件: %s\n" "$file"
    echo "--------------------------------------"
    tail -n 100 "$file" 2>/dev/null
    echo ""
    read -p "按回车键继续..." dummy
}

# 实时跟踪
tail_follow() {
    local file="$1"
    if [ ! -f "$file" ]; then
        printf "${RED}日志文件不存在: %s${NC}\n" "$file"
        read -p "按回车键继续..." dummy
        return
    fi
    printf "${GREEN}实时跟踪 %s (按 Ctrl+C 退出)...${NC}\n" "$file"
    sleep 1
    tail -f "$file"
    echo ""
    read -p "已退出跟踪，按回车键继续..." dummy
}

# 按关键字搜索
search_log() {
    local file="$1"
    if [ ! -f "$file" ]; then
        printf "${RED}日志文件不存在: %s${NC}\n" "$file"
        read -p "按回车键继续..." dummy
        return
    fi
    read -p "输入搜索关键词: " keyword
    [ -z "$keyword" ] && return
    printf "${GREEN}搜索 '%s' 在 %s${NC}\n" "$keyword" "$file"
    grep -i --color=auto "$keyword" "$file" | tail -n 50
    echo ""
    read -p "按回车键继续..." dummy
}

# 清理日志（谨慎操作）
clean_logs() {
    printf "${RED}⚠ 清理日志会清空以下文件内容:${NC}\n"
    echo "$AUTH_LOG"
    echo "$SYS_LOG"
    echo "$KERN_LOG"
    echo "$FAIL2BAN_LOG"
    read -p "确认清空以上所有日志？[y/N]: " confirm
    if [[ $confirm =~ ^[Yy]$ ]]; then
        for f in "$AUTH_LOG" "$SYS_LOG" "$KERN_LOG" "$FAIL2BAN_LOG"; do
            [ -f "$f" ] && : > "$f"
        done
        printf "${GREEN}日志已清空。${NC}\n"
    else
        printf "已取消。\n"
    fi
    read -p "按回车键继续..." dummy
}

# 主菜单
while true; do
    clear
    printf "${BLUE}===== 日志查看与分析 =====${NC}\n"
    echo "1. 认证日志 (auth.log / secure)"
    echo "2. 系统日志 (syslog / messages)"
    echo "3. 内核日志 (kern.log / dmesg)"
    [ -f "$FAIL2BAN_LOG" ] && echo "4. Fail2Ban 日志"
    [ -d /var/log/nginx ] && echo "5. Nginx 访问日志"
    echo ""
    echo "6. 实时跟踪自定义日志"
    echo "7. 搜索日志关键词"
    echo "8. 清理日志 (危险)"
    echo "0. 返回主菜单"
    read -p "请选择: " choice

    case $choice in
        1) view_log "$AUTH_LOG" "认证日志" ;;
        2) view_log "$SYS_LOG" "系统日志" ;;
        3)
            if [ -f "$KERN_LOG" ]; then
                view_log "$KERN_LOG" "内核日志"
            else
                printf "${BLUE}内核环形缓冲区 (最近 100 行)${NC}\n"
                dmesg | tail -n 100
                read -p "按回车键继续..." dummy
            fi
            ;;
        4)
            if [ -f "$FAIL2BAN_LOG" ]; then
                view_log "$FAIL2BAN_LOG" "Fail2Ban 日志"
            else
                printf "${RED}Fail2Ban 日志不存在${NC}\n"
                read -p "按回车键继续..." dummy
            fi
            ;;
        5)
            if [ -d /var/log/nginx ]; then
                view_log "$NGINX_LOG" "Nginx 访问日志"
            else
                printf "${RED}Nginx 日志目录不存在${NC}\n"
                read -p "按回车键继续..." dummy
            fi
            ;;
        6)
            read -p "输入要跟踪的日志文件完整路径: " custom_log
            [ -f "$custom_log" ] && tail_follow "$custom_log" || printf "${RED}文件不存在${NC}\n"
            read -p "按回车键继续..." dummy
            ;;
        7)
            echo "选择日志文件:"
            echo "1. 认证日志"
            echo "2. 系统日志"
            echo "3. 内核日志"
            [ -f "$FAIL2BAN_LOG" ] && echo "4. Fail2Ban 日志"
            read -p "选择文件: " log_choice
            case $log_choice in
                1) search_log "$AUTH_LOG" ;;
                2) search_log "$SYS_LOG" ;;
                3) [ -f "$KERN_LOG" ] && search_log "$KERN_LOG" || printf "${RED}内核日志文件缺失${NC}\n";;
                4) [ -f "$FAIL2BAN_LOG" ] && search_log "$FAIL2BAN_LOG" || printf "${RED}Fail2Ban 日志缺失${NC}\n";;
                *) printf "${RED}无效选项${NC}\n";;
            esac
            read -p "按回车键继续..." dummy
            ;;
        8) clean_logs ;;
        0) break ;;
        *) printf "${RED}无效选项${NC}\n"; sleep 1 ;;
    esac
done
