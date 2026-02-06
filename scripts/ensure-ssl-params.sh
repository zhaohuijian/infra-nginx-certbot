#!/usr/bin/env bash
# 确保 nginx/ssl 下存在 Certbot 推荐的 TLS 参数（若缺失则从官方仓库下载）
# 使用后 Nginx 通过挂载读取，无需在 certbot/conf 下生成或存放。
set -e
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SSL_DIR="${REPO_ROOT}/nginx/ssl"
OPTIONS_URL="https://raw.githubusercontent.com/certbot/certbot/master/certbot-nginx/certbot_nginx/_internal/tls_configs/options-ssl-nginx.conf"
DHPARAMS_URL="https://raw.githubusercontent.com/certbot/certbot/master/certbot/certbot/ssl-dhparams.pem"

mkdir -p "$SSL_DIR"
need_download=false

if [[ ! -f "$SSL_DIR/options-ssl-nginx.conf" ]]; then
  echo "[info] 下载 options-ssl-nginx.conf ..."
  curl -sSf "$OPTIONS_URL" -o "$SSL_DIR/options-ssl-nginx.conf"
  need_download=true
fi

if [[ ! -f "$SSL_DIR/ssl-dhparams.pem" ]]; then
  echo "[info] 下载 ssl-dhparams.pem ..."
  curl -sSf "$DHPARAMS_URL" -o "$SSL_DIR/ssl-dhparams.pem"
  need_download=true
fi

if [[ "$need_download" == false ]]; then
  echo "[ok] nginx/ssl 下 TLS 参数已存在，无需下载"
else
  echo "[ok] TLS 参数已就绪: $SSL_DIR"
fi
