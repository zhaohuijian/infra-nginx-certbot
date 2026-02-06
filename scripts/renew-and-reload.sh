#!/usr/bin/env bash
# 执行证书续期并在成功时重载 Nginx（建议由 cron 调用，例如每天 3:00）
# 与 compose 中 certbot 容器内的 12h 续期二选一：要么用本脚本替代容器内循环，要么保留容器内续期并仅用本脚本做“续期后重载”。
# 用法: 在宿主机 cron 中: 0 3 * * * /path/to/infra-nginx-certbot/scripts/renew-and-reload.sh
set -e
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
COMPOSE_FILE="${REPO_ROOT}/docker-compose.yml"
NGINX_CONTAINER="${NGINX_CONTAINER:-nginx-proxy}"

cd "$REPO_ROOT"

# 使用 compose 中 certbot 服务执行一次性续期（与 init-cert.sh 一致，单一事实来源）
docker compose -f "$COMPOSE_FILE" run --rm \
  --entrypoint certbot \
  certbot \
  renew --webroot -w /var/www/certbot --quiet

# 续期成功或无需续期时都重载 nginx，确保使用最新证书
docker compose -f "$COMPOSE_FILE" exec -T "$NGINX_CONTAINER" nginx -s reload 2>/dev/null || true
echo "[ok] renew-and-reload 完成 $(date -Iseconds 2>/dev/null || date)"
