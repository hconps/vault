#!/bin/bash

# 一键部署 Vaultwarden + Caddy 脚本
# 用法: ./deploy.sh <域名> <邮箱> [vaultwarden端口,默认8080]

set -e

DOMAIN=$1
EMAIL=$2
VW_PORT=${3:-8080}

if [[ -z "$DOMAIN" || -z "$EMAIL" ]]; then
    echo "用法: $0 <域名> <邮箱> [vaultwarden端口,默认8080]"
    exit 1
fi

# 安装 Docker 和 Docker Compose
if ! command -v docker &>/dev/null; then
    curl -fsSL https://get.docker.com | bash
fi
if ! command -v docker-compose &>/dev/null; then
    curl -L "https://github.com/docker/compose/releases/latest/download/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose
    chmod +x /usr/local/bin/docker-compose
fi

mkdir -p vaultwarden-caddy && cd vaultwarden-caddy

# 生成 docker-compose.yml
cat > docker-compose.yml <<EOF
version: "3"
services:
    vaultwarden:
        image: vaultwarden/server:latest
        container_name: vaultwarden
        restart: unless-stopped
        environment:
            - WEBSOCKET_ENABLED=true
        volumes:
            - ./vw-data:/data
        ports:
            - "${VW_PORT}:80"

    caddy:
        image: caddy:alpine
        container_name: caddy
        restart: unless-stopped
        ports:
            - "80:80"
            - "443:443"
        volumes:
            - ./Caddyfile:/etc/caddy/Caddyfile
            - ./caddy-data:/data
            - ./caddy-config:/config
EOF

# 生成 Caddyfile
cat > Caddyfile <<EOF
${DOMAIN} {
    reverse_proxy vaultwarden:${VW_PORT}
    encode gzip
    tls ${EMAIL}
}
EOF

# 启动服务
docker-compose up -d

echo "部署完成！"
echo "请访问: https://${DOMAIN}"
