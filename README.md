
快捷键 vp

curl -sSL https://raw.githubusercontent.com/lje02/liang/main/vp/install.sh | bash



# 安装数据库和缓存redis:⬇️

curl -fsSL https://raw.githubusercontent.com/lje02/liang/main/infra-shared.sh -o /usr/local/bin/infra-shared.sh && chmod +x /usr/local/bin/infra-shared.sh && /usr/local/bin/infra-shared.sh


# 查看密码

grep REDIS_PASSWORD /srv/infra/.env

greg MARIADB_PASSWORD /srv/infra/.env

# 运行管理

infra-shared.sh

