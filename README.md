
快捷键 vp

# 下载
curl -fsSL https://raw.githubusercontent.com/lje02/liang/main/infra-mariadb.sh -o infra-mariadb.sh
curl -fsSL https://raw.githubusercontent.com/lje02/liang/main/infra-redis.sh   -o infra-redis.sh
chmod +x infra-mariadb.sh infra-redis.sh





# 安装数据库和缓存redis:⬇️

curl -fsSL https://raw.githubusercontent.com/lje02/liang/main/infra-shared.sh -o /usr/local/bin/infra-shared.sh && chmod +x /usr/local/bin/infra-shared.sh && /usr/local/bin/infra-shared.sh


# 查看密码

grep REDIS_PASSWORD /srv/infra/.env

cd /srv/infra

sudo cat .env

# 运行管理

infra-shared.sh

