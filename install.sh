#!/bin/bash

# ========== 可通过参数指定的变量 ==========
DOMAIN=""
CF_API_TOKEN=""
EMAIL=""
ONEDRIVE_AUTH_URL=""
ONEDRIVE_DOWNLOAD=true

# ========== 解析参数 ==========
while [[ $# -gt 0 ]]; do
  case "$1" in
    --domain) DOMAIN="$2"; shift 2 ;;
    --cf-api-token) CF_API_TOKEN="$2"; shift 2 ;;
    --email) EMAIL="$2"; shift 2 ;;
    --onedrive-auth-url) ONEDRIVE_AUTH_URL="$2"; shift 2 ;;
    --no-onedrive-download) ONEDRIVE_DOWNLOAD=false; shift ;;
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

# ========== 配置 OneDrive ==========
if $ONEDRIVE_DOWNLOAD; then
  echo -e "\n>>> 安装 OneDrive CLI"
  add-apt-repository universe -y && apt install -y onedrive
fi

mkdir -p /root/.config/onedrive
cat > /root/.config/onedrive/config <<EOF
sync_dir = "/opt/vaultwarden/data"
EOF

if [[ -n "$ONEDRIVE_AUTH_URL" ]]; then
  echo "正在使用授权 URL 完成登录..."
  echo "$ONEDRIVE_AUTH_URL" | onedrive --synchronize --authorize
else
  echo -e "\n>>> 请打开授权链接完成 OneDrive 登录："
  onedrive --synchronize --auth-response
  echo -e "\n登录完成后，系统将自动开始实时同步。"
fi

# ========== 设置 OneDrive 为 systemd 服务 ==========
cat > /etc/systemd/system/onedrive.service <<EOF
[Unit]
Description=OneDrive Sync Service
After=network-online.target docker.service
Wants=network-online.target

[Service]
ExecStart=/usr/bin/onedrive --monitor --syncdir "/opt/vaultwarden/data"
Restart=always
User=root

[Install]
WantedBy=default.target
EOF

systemctl daemon-reload
systemctl enable --now onedrive

# ========== 安装 rclone 并配置每日备份 ==========
curl https://rclone.org/install.sh | bash

echo -e "\n>>> 请配置 rclone（选择 OneDrive 类型，完成授权）"
rclone config

# ========== 创建每日备份脚本 ==========
cat > /usr/local/bin/vaultwarden_backup.sh <<EOF
#!/bin/bash
TIMESTAMP=\$(date +%F)
BACKUP_FILE="/tmp/vaultwarden-\$TIMESTAMP.zip"
zip -r \$BACKUP_FILE /opt/vaultwarden/data
rclone copy \$BACKUP_FILE remote:VaultwardenBackup
rm -f \$BACKUP_FILE
EOF
chmod +x /usr/local/bin/vaultwarden_backup.sh

# ========== 加入每日 cron ==========
(crontab -l 2>/dev/null; echo "0 3 * * * /usr/local/bin/vaultwarden_backup.sh") | crontab -

echo -e "\n✅ 部署完成！"
echo -e "访问地址：https://$DOMAIN"
