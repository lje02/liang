install_singbox() {
    printf "${BLUE}正在安装 sing-box 脚本...${NC}\n"
    
    # 先用临时文件保存安装脚本，避免管道执行时 $0 失效
    local tmp_install="/tmp/singbox_install.sh"
    curl -sSL "$SINGBOX_INSTALL_URL" -o "$tmp_install"
    
    if [ ! -s "$tmp_install" ]; then
        printf "${RED}下载安装脚本失败，请检查网络。${NC}\n"
        read -p "按回车键继续..." dummy
        return 1
    fi
    
    chmod +x "$tmp_install"
    
    # 执行安装脚本（作为文件执行，$0 会指向脚本自身）
    if bash "$tmp_install"; then
        printf "${GREEN}sing-box 安装完成！${NC}\n"
        
        # 等待系统更新 PATH
        sleep 1
        hash -r 2>/dev/null
        
        # 验证 ssb 是否成功创建
        if command -v ssb &>/dev/null; then
            printf "${GREEN}ssb 命令已就绪。${NC}\n"
        else
            # ssb 创建失败，手动补救
            printf "${YELLOW}ssb 命令未自动创建，尝试手动修复...${NC}\n"
            
            if [ -f "$tmp_install" ]; then
                # 直接把安装脚本复制为 ssb
                cp "$tmp_install" /usr/local/bin/ssb
                chmod +x /usr/local/bin/ssb
                printf "${GREEN}已手动创建 ssb 命令。${NC}\n"
            elif [ -f /usr/local/bin/sing-box ]; then
                # 另一个方案：从 GitHub 重新下载
                curl -sSL "$SINGBOX_INSTALL_URL" -o /usr/local/bin/ssb
                chmod +x /usr/local/bin/ssb
                printf "${GREEN}已从 GitHub 重新下载 ssb。${NC}\n"
            fi
        fi
        
        # 清理临时文件
        rm -f "$tmp_install"
    else
        printf "${RED}安装失败，请检查网络。${NC}\n"
        rm -f "$tmp_install"
    fi
    
    read -p "按回车键继续..." dummy
}