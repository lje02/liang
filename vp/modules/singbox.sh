install_singbox() {
    printf "${BLUE}正在安装 sing-box 脚本...${NC}\n"
    if bash <(curl -sSL "$SINGBOX_INSTALL_URL"); then
        printf "${GREEN}sing-box 安装完成！${NC}\n"
        
        # 如果 ssb 命令不存在，尝试创建
        if ! command -v ssb &>/dev/null; then
            # 方法1：查找 sing-box 可执行文件所在目录，看有没有 ssb
            local singbox_dir=$(dirname "$(which sing-box 2>/dev/null)" 2>/dev/null)
            
            if [ -x "$singbox_dir/ssb" ]; then
                # ssb 和 sing-box 在同一目录，创建软链接
                ln -sf "$singbox_dir/ssb" /usr/local/bin/ssb
                printf "${GREEN}已创建 ssb 软链接。${NC}\n"
            elif [ -x /usr/local/bin/ssb ]; then
                # ssb 在 /usr/local/bin 但没被 PATH 找到（极少情况）
                export PATH="$PATH:/usr/local/bin"
                printf "${GREEN}ssb 已存在，已更新 PATH。${NC}\n"
            else
                # ssb 文件找不到，尝试从 GitHub 单独下载
                printf "${YELLOW}未找到 ssb，正在尝试下载...${NC}\n"
                local ssb_url="https://raw.githubusercontent.com/lje02/sing/main/ssb.sh"
                curl -sSL "$ssb_url" -o /usr/local/bin/ssb && chmod +x /usr/local/bin/ssb && \
                printf "${GREEN}ssb 已下载并安装到 /usr/local/bin/ssb${NC}\n" || \
                printf "${YELLOW}ssb 下载失败，请检查 sing-box 仓库中是否有 ssb.sh 文件。${NC}\n"
            fi
        else
            printf "${GREEN}ssb 命令已就绪。${NC}\n"
        fi
    else
        printf "${RED}安装失败，请检查网络。${NC}\n"
    fi
    read -p "按回车键继续..." dummy
}