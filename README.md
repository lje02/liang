# docker安装

```bash
curl -fsSL https://get.docker.com | sh
```
# 开机自启

systemctl enable docker --now



# 分布式wordpress

curl -fsSL https://raw.githubusercontent.com/lje02/liang/main/wp-deploy.sh -o /usr/local/bin/wp-deploy.sh && chmod +x /usr/local/bin/wp-deploy.sh && /usr/local/bin/wp-deploy.sh


# 安装数据库和缓存redis:⬇️

curl -fsSL https://raw.githubusercontent.com/lje02/liang/main/infra-shared.sh -o /usr/local/bin/infra-shared.sh && chmod +x /usr/local/bin/infra-shared.sh && /usr/local/bin/infra-shared.sh


# 查看密码

grep REDIS_PASSWORD /srv/infra/.env

cd /srv/infra

sudo cat .env

# 运行管理

infra-shared.sh

