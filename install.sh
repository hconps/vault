#!/bin/bash

# ========== 可通过参数指定的变量 ==========
DOMAIN=""
CF_API_TOKEN=""
EMAIL=""

# ========== 解析参数 ==========
while [[ $# -gt 0 ]]; do
  case "$1" in
    --domain) DOMAIN="$2"; shift 2 ;;
    --cf-api-token) CF_API_TOKEN="$2"; shift 2 ;;
    --email) EMAIL="$2"; shift 2 ;;
    *) echo "未知参数: $1"; exit 1 ;;
  esac
done

# ========== 交互式输入 ==========
[[ -z "$DOMAIN" ]] && read -p "请输入你的域名（用于反代 Vaultwarden）: " DOMAIN
[[ -z "$CF_API_TOKEN" ]] && read -p "请输入你的 Cloudflare API Token: " CF_API_TOKEN
[[ -z "$EMAIL" ]] && read -p "请输入你的邮箱（用于 Caddy 注册）: " EMAIL

# ========== 安装必要组件 ==========
apt update && apt install -y curl unzip git docker.io docker-compose sqlite3 systemd-cron

# ========== 安装带 Cloudflare DNS 插件的 Caddy ==========
mkdir -p /opt/caddy
curl -sSL "https://caddyserver.com/api/download?os=linux&arch=amd64&idempotency=123&plugins=tls.dns.cloudflare" -o /opt/caddy/caddy.tar.gz
tar -xf /opt/caddy/caddy.tar.gz -C /opt/caddy
install /opt/caddy/caddy /usr/local/bin/caddy
setcap cap_net_bind_service=+ep /usr/local/bin/caddy

# ========== 创建 Vaultwarden 项目目录 ==========
mkdir -p /opt/vaultwarden/data
cd /opt/vaultwarden

# ========== 创建 docker-compose.yml ==========
cat > docker-compose.yml <<EOF
version: "3"

services:
  vaultwarden:
    image: vaultwarden/server:latest
    container_name: vaultwarden
    restart: unless-stopped
    volumes:
      - ./data:/data
    environment:
      - DOMAIN=https://${DOMAIN}
    networks:
      - vaultwarden_net

networks:
  vaultwarden_net:
    driver: bridge
EOF

# ========== 创建 Caddyfile ==========
mkdir -p /etc/caddy

cat > /etc/caddy/Caddyfile <<EOF
$DOMAIN {
  reverse_proxy 127.0.0.1:8000
  tls {
    dns cloudflare \$CF_API_TOKEN
    email $EMAIL
  }
}
EOF

# ========== Caddy systemd 配置 ==========
cat > /etc/systemd/system/caddy.service <<EOF
[Unit]
Description=Caddy Web Server
After=network.target docker.service
Requires=docker.service

[Service]
ExecStart=/usr/local/bin/caddy run --config /etc/caddy/Caddyfile --adapter caddyfile
ExecReload=/usr/local/bin/caddy reload --config /etc/caddy/Caddyfile --adapter caddyfile
Restart=on-failure

Environment="CF_API_TOKEN=$CF_API_TOKEN"
Environment="EMAIL=$EMAIL"

[Install]
WantedBy=multi-user.target
EOF

# ========== 启动 Vaultwarden ==========
docker-compose up -d

# ========== 启动 Caddy ==========
systemctl daemon-reexec
systemctl daemon-reload
systemctl enable --now caddy



echo -e "\n✅ 部署完成！"
echo -e "访问地址：https://$DOMAIN"
